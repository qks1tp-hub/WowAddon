-- GoldWorldQuests
-- 로그인 시 현재 대륙의 전역 퀘스트 중 "골드"가 보상으로 포함된 퀘스트를 채팅창에 알려줍니다.
-- Midnight(12.x) 클라이언트 API 기준으로 작성됨.

local ADDON_NAME = ...

local PREFIX = "|cff00ff00[전역퀘-골드]|r "

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

local hasScannedThisSession = false
local pendingQuests = {}

local MAX_RETRIES = 6      -- 보상 데이터 로드 재시도 횟수
local RETRY_INTERVAL = 1.0 -- 재시도 간격(초)

local function Print(msg)
    print(PREFIX .. msg)
end

-- C_TaskQuest.GetQuestsForPlayerByMapID 는 Midnight(12.x)부터 deprecated 되어
-- C_TaskQuest.GetQuestsOnMap 으로 대체되었다. 새 함수가 있으면 그것을 쓰고,
-- 없는 클라이언트(구버전)에서는 예전 함수로 폴백한다.
local GetTaskQuestsOnMap = C_TaskQuest.GetQuestsOnMap or C_TaskQuest.GetQuestsForPlayerByMapID

-- 플레이어가 현재 위치한 "대륙(Continent)" mapID를 찾는다.
local function GetCurrentContinentMapID()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then
        return nil
    end

    local info = C_Map.GetMapInfo(mapID)
    while info and info.mapType and info.mapType ~= Enum.UIMapType.Continent do
        if not info.parentMapID or info.parentMapID == 0 then
            break
        end
        info = C_Map.GetMapInfo(info.parentMapID)
    end

    if info and info.mapType == Enum.UIMapType.Continent then
        return info.mapID
    end

    return nil
end

-- 대륙 하위의 모든 zone mapID를 수집한다.
local function CollectZoneMapIDs(continentMapID)
    local result = {}
    local children = C_Map.GetMapChildrenInfo(continentMapID, Enum.UIMapType.Zone, true)
    if children then
        for _, child in ipairs(children) do
            table.insert(result, child.mapID)
        end
    end
    return result
end

-- questID/questId 필드명이 패치마다 달라질 수 있어 방어적으로 처리
local function GetQuestIDFromTaskInfo(taskInfo)
    return taskInfo.questID or taskInfo.questId
end

-- 진짜 "전역 퀘스트"인지 판별한다.
-- taskInfo.worldQuestType 은 전역 퀘스트에만 채워지는 값이라 가장 신뢰도가 높다.
-- (팔로워 퀘스트, 보너스 목표물 등은 nil)
-- 추가로 C_QuestLog.IsWorldQuest 로 한 번 더 교차 확인한다.
local function IsRealWorldQuest(taskInfo, questID)
    if taskInfo.worldQuestType ~= nil then
        return true
    end
    local ok, result = pcall(C_QuestLog.IsWorldQuest, questID)
    return ok and result
end

-- 남은 시간(초)을 "n시간 m분" / "m분" 형태의 문자열로 변환한다.
local function FormatTimeLeft(seconds)
    if not seconds or seconds <= 0 then
        return "시간 정보 없음"
    end

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)

    if hours > 0 then
        return string.format("%d시간 %d분 남음", hours, minutes)
    else
        return string.format("%d분 남음", minutes)
    end
end

-- 퀘스트의 남은 시간을 초 단위로 가져온다. (신버전 함수 우선, 없으면 구버전 폴백)
local function GetQuestTimeLeftSeconds(questID)
    if C_TaskQuest.GetQuestTimeLeftSeconds then
        return C_TaskQuest.GetQuestTimeLeftSeconds(questID)
    elseif C_TaskQuest.GetQuestTimeLeftMinutes then
        local minutes = C_TaskQuest.GetQuestTimeLeftMinutes(questID)
        return minutes and (minutes * 60) or nil
    end
    return nil
end

-- 퀘스트가 실제로 속한 zone의 이름을 가져온다.
-- 주의: GetQuestsOnMap(zoneMapID)는 경계 지역의 퀘스트를 인접 zone에서도
-- 함께 반환하는 경우가 있어, "어느 zone을 스캔하다가 발견했는지"만으로
-- 지역명을 정하면 가끔 엉뚱한 zone 이름이 나올 수 있다.
-- 그래서 C_TaskQuest.GetQuestZoneID로 퀘스트의 진짜 소속 zone을 다시 확인한다.
local function GetCanonicalZoneName(questID, fallbackZoneName)
    if C_TaskQuest.GetQuestZoneID then
        local ok, zoneMapID = pcall(C_TaskQuest.GetQuestZoneID, questID)
        if ok and zoneMapID and zoneMapID > 0 then
            local zoneInfo = C_Map.GetMapInfo(zoneMapID)
            if zoneInfo and zoneInfo.name then
                return zoneInfo.name
            end
        end
    end
    return fallbackZoneName
end

local foundGoldQuests = {} -- { {questID=, title=, zoneName=, secondsLeft=}, ... }

-- questID 하나의 보상 데이터가 로드됐는지 확인하고, 골드 보상이 있으면
-- foundGoldQuests 리스트에 정보를 모아둔다 (출력/추적은 마지막에 일괄 처리).
-- 아직 로드가 안 됐으면 false를 반환해서 재시도하도록 한다.
local function TryReportGoldReward(questID, data)
    if not HaveQuestRewardData(questID) then
        return false -- 아직 로드 안 됨, 나중에 다시 시도
    end

    local money = GetQuestLogRewardMoney(questID)
    if money and money > 0 then
        local title = C_QuestLog.GetTitleForQuestID(questID) or ("퀘스트 #" .. questID)
        local zoneName = GetCanonicalZoneName(questID, data.zoneName)
        local secondsLeft = GetQuestTimeLeftSeconds(questID)

        table.insert(foundGoldQuests, {
            questID = questID,
            title = title,
            zoneName = zoneName,
            secondsLeft = secondsLeft,
        })
    end

    return true -- 로드 완료(골드가 없더라도 처리 끝)
end

-- 하나의 골드 전역퀘 정보를 채팅창에 출력한다.
local function PrintGoldQuest(entry)
    local timeLeft = FormatTimeLeft(entry.secondsLeft)
    -- 남은 시간이 1시간(3600초) 미만이면 빨간색으로 강조
    if entry.secondsLeft and entry.secondsLeft > 0 and entry.secondsLeft < 3600 then
        timeLeft = "|cffff0000" .. timeLeft .. "|r"
    end
    Print(string.format("%s |cffaaaaaa(%s)|r - %s",
        entry.title, entry.zoneName or "알 수 없는 지역", timeLeft))
end

-- 모든 골드 전역퀘를 출력하고, 그중 남은 시간이 가장 적은 퀘스트를 추적한다.
local function FinalizeResults()
    if #foundGoldQuests == 0 then
        Print("골드 보상 전역 퀘스트를 찾지 못했습니다.")
        return
    end

    for _, entry in ipairs(foundGoldQuests) do
        PrintGoldQuest(entry)
    end

    -- 남은 시간이 확인되는 퀘스트 중에서만 최소값을 찾는다.
    local urgent = nil
    for _, entry in ipairs(foundGoldQuests) do
        if entry.secondsLeft and entry.secondsLeft > 0 then
            if not urgent or entry.secondsLeft < urgent.secondsLeft then
                urgent = entry
            end
        end
    end

    if not urgent then
        Print("남은 시간을 확인할 수 있는 퀘스트가 없어 추적하지 않았습니다.")
        return
    end

    if C_QuestLog.AddWorldQuestWatch then
        pcall(C_QuestLog.AddWorldQuestWatch, urgent.questID)
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        pcall(C_SuperTrack.SetSuperTrackedQuestID, urgent.questID)
    end

    Print(string.format("|cffffff00%s|r |cffaaaaaa(%s)|r 를 추적합니다 (남은 시간이 가장 적음: %s)",
        urgent.title, urgent.zoneName or "알 수 없는 지역", FormatTimeLeft(urgent.secondsLeft)))
end

local function CheckPendingQuests(attempt)
    attempt = attempt or 1

    local stillPending = {}
    for questID, data in pairs(pendingQuests) do
        local done = TryReportGoldReward(questID, data)
        if not done then
            stillPending[questID] = data
        end
    end

    pendingQuests = stillPending

    if next(pendingQuests) == nil then
        FinalizeResults()
        return -- 모두 처리 완료
    end

    if attempt >= MAX_RETRIES then
        -- 끝까지 로드 안 된 퀘스트는 포기하고 지금까지 모인 결과로 마무리
        pendingQuests = {}
        FinalizeResults()
        return
    end

    -- 아직 로드 안 된 퀘스트들은 다시 프리로드 요청 후 재시도
    for questID in pairs(pendingQuests) do
        C_TaskQuest.RequestPreloadRewardData(questID)
    end
    C_Timer.After(RETRY_INTERVAL, function() CheckPendingQuests(attempt + 1) end)
end

local function ScanForGoldWorldQuests()
    wipe(pendingQuests)
    wipe(foundGoldQuests)

    local continentMapID = GetCurrentContinentMapID()
    if not continentMapID then
        Print("현재 대륙 정보를 확인할 수 없습니다. 잠시 후 /gwq 로 다시 시도해 주세요.")
        return
    end

    local zoneMapIDs = CollectZoneMapIDs(continentMapID)
    if #zoneMapIDs == 0 then
        table.insert(zoneMapIDs, continentMapID)
    end

    local candidateCount = 0

    for _, zoneMapID in ipairs(zoneMapIDs) do
        local zoneInfo = C_Map.GetMapInfo(zoneMapID)
        local zoneName = zoneInfo and zoneInfo.name or "알 수 없는 지역"

        local taskInfos = GetTaskQuestsOnMap(zoneMapID)
        if taskInfos then
            for _, taskInfo in ipairs(taskInfos) do
                local questID = GetQuestIDFromTaskInfo(taskInfo)
                if questID and IsRealWorldQuest(taskInfo, questID) then
                    pendingQuests[questID] = { zoneName = zoneName }
                    C_TaskQuest.RequestPreloadRewardData(questID)
                    candidateCount = candidateCount + 1
                end
            end
        end
    end

    if candidateCount == 0 then
        Print("현재 대륙에서 진행 중인 전역 퀘스트를 찾지 못했습니다.")
        return
    end

    -- 서버에서 보상 데이터가 도착할 시간을 확보 (로드 확인 후 재시도 방식)
    C_Timer.After(1.5, function() CheckPendingQuests(1) end)
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if (isLogin or isReload) and not hasScannedThisSession then
            hasScannedThisSession = true
            -- 로그인 직후에는 맵/퀘스트 데이터가 아직 준비 안 되어 있을 수 있어 약간 지연
            C_Timer.After(3, ScanForGoldWorldQuests)
        end
    end
end)

SLASH_GOLDWQ1 = "/gwq"
SlashCmdList["GOLDWQ"] = function()
    Print("전역 퀘스트를 다시 검색합니다...")
    ScanForGoldWorldQuests()
end