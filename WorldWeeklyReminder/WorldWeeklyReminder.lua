local ADDON_NAME = ...

local WeeklyActivities = {
    {
        name = "룬석 방어",
        quests = {
            90573, -- Magisters
            90574, -- Blood Knights
            90575, -- Farstriders
            90576, -- Shades of the Row
        },
    },

    {
        name = "풍요",
        quests = {
            89507, -- An Abundance of Wealth
        },
    },

    {
        name = "하라니르의 전설",
        quests = {
            92713, -- Legendary Prosperity
        },
    },

    {
        name = "스토마리온 강습",
        quests = {
            90962, -- Guarded Treasures
        },
    },

    {
        name = "사냥감",
        quests = {
            94446,
        },
    },

    {
        name = "쇄도",
        quests = {
            96995,
        },
    },

    {
        name = "특별 과제",
        quests = {
            96307,
            92848,
            96492,
            94866,
            96029,
            94390,
            94391,
            94865,
            94795,
        },
    },
}


--------------------------------------------------
-- 이번 주 활동 완료 여부
--------------------------------------------------

local function IsActivityCompleted(activity)

    for _, questID in ipairs(activity.quests) do
        
        local onQuest = C_QuestLog.IsOnQuest(questID)

        if activity.name == "특별 과제" then
            if not onQuest then
                break
            end
        end

        local completed = C_QuestLog.IsQuestFlaggedCompleted(questID)

        if completed then
            return true
        end
    end

    return false
end


--------------------------------------------------
-- 주간 활동 검사
--------------------------------------------------

local function CheckWeeklyActivities()

    local incompleteCount = 0

    for _, activity in ipairs(WeeklyActivities) do
        
        -- Quest ID가 등록된 활동만 검사
        if #activity.quests > 0 then

            if not IsActivityCompleted(activity) then

                print(
                    "|cffff3333❌ "
                    .. activity.name
                    .. "|r"
                )

                incompleteCount = incompleteCount + 1
            end
        end
    end

    -- 미완료가 하나도 없을 때만 출력
    if incompleteCount == 0 then
        print("|cff00ff00이번 주 주요 주간 활동을 모두 완료했습니다!|r")
    end
end


--------------------------------------------------
-- 로그인
--------------------------------------------------

local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event)

    if event == "PLAYER_LOGIN" then

        C_Timer.After(3, function()
            CheckWeeklyActivities()
        end)

    end
end)


--------------------------------------------------
-- 슬래시 명령어
--------------------------------------------------

SLASH_WORLDWEEKLYREMINDER1 = "/wwr"
SLASH_WORLDWEEKLYREMINDER2 = "/주간"

SlashCmdList["WORLDWEEKLYREMINDER"] = function()
    CheckWeeklyActivities()
end
