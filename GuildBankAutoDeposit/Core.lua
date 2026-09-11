-- GuildBankAutoDeposit
-- 길드은행 창에 "모두 넣기" / "모두 꺼내기" 버튼을 추가합니다.
-- 현재 보고 있는 탭에 해당하는 분류의 아이템만 대상으로 동작합니다.
--   착귀            -> 미귀속 착용시귀속(BoE) 장비
--   요리낚시재료     -> Tradeskill/Cooking (subclassID 8, 낚시로 잡은 물고기 포함)
--   채광재료         -> Tradeskill/Metal & Stone (subclassID 7)
--   약초재료         -> Tradeskill/Herb (subclassID 9)
--   천가죽재료       -> Tradeskill/Cloth, Leather (subclassID 5, 6)

local ADDON_NAME = "GuildBankAutoDeposit"
local PREFIX = "|cff33ccffGBAD|r"

-- =========================================================
-- 저장 변수 초기화
-- =========================================================
local defaults = {
    tabNames = {
        boe = "착귀",
        cookfish = "요리낚시재료",
        mining = "채광재료",
        herb = "약초재료",
        clothleather = "천가죽재료",
    },
    ignore = {}, -- [itemID] = true
}

local db

local function DeepCopyDefaultsInto(target, defaultTable)
    for k, v in pairs(defaultTable) do
        if type(v) == "table" then
            target[k] = target[k] or {}
            DeepCopyDefaultsInto(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

local function InitDB()
    GuildBankAutoDepositDB = GuildBankAutoDepositDB or {}
    DeepCopyDefaultsInto(GuildBankAutoDepositDB, defaults)
    db = GuildBankAutoDepositDB
end

-- =========================================================
-- 아이템 분류
-- =========================================================
local TRADEGOODS_CLASS_ID = Enum.ItemClass and Enum.ItemClass.Tradegoods or 7
local BIND_ON_EQUIP = Enum.ItemBind and Enum.ItemBind.OnEquip or 2

-- Tradeskill(classID 7) subclassID -> 카테고리 키
local SUBCLASS_TO_CATEGORY = {
    [5] = "clothleather", -- Cloth
    [6] = "clothleather", -- Leather
    [7] = "mining",       -- Metal & Stone
    [8] = "cookfish",     -- Cooking (낚시로 얻는 물고기 포함)
    [9] = "herb",         -- Herb
}

local function IsIgnored(itemID)
    return db.ignore[itemID] == true
end

local function IsUnboundBindOnEquip(itemID)
    if not itemID then return false end
    local bindType = select(14, GetItemInfo(itemID))
    return bindType == BIND_ON_EQUIP
end

-- 가방 아이템 하나를 카테고리 키("boe"/"cookfish"/"mining"/"herb"/"clothleather") 또는 nil 로 분류
local function ClassifyBagItem(info)
    if not info or not info.itemID then return nil end
    if info.isLocked then return nil end
    if info.isBound then return nil end -- 이미 귀속된 아이템은 대상에서 제외
    if IsIgnored(info.itemID) then return nil end

    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(info.itemID)

    if classID == TRADEGOODS_CLASS_ID then
        return SUBCLASS_TO_CATEGORY[subclassID] -- 매핑 없는 하위분류(보석세공/마법부여/원소 등)는 nil
    end

    if IsUnboundBindOnEquip(info.itemID) then
        return "boe"
    end

    return nil
end

-- 대상 가방 목록: 0 = 배낭, 1~4 = 일반 가방, 5 = 시약 가방(존재하는 경우)
local BAG_IDS = {0, 1, 2, 3, 4, 5}

-- 가방 전체 스캔 -> { boe = {...}, cookfish = {...}, mining = {...}, herb = {...}, clothleather = {...} }
local function ScanBags()
    local result = {}
    for category in pairs(db.tabNames) do
        result[category] = {}
    end
    for _, bag in ipairs(BAG_IDS) do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                local category = ClassifyBagItem(info)
                if category and result[category] then
                    table.insert(result[category], {
                        bag = bag,
                        slot = slot,
                        itemID = info.itemID,
                        count = info.stackCount or 1,
                        link = info.hyperlink,
                    })
                end
            end
        end
    end
    return result
end

-- =========================================================
-- 길드은행 탭 유틸리티
-- =========================================================
local GUILDBANK_SLOTS_PER_TAB = MAX_GUILDBANK_SLOTS_PER_TAB or 98

-- 이름으로 탭 번호 찾기
local function ResolveTabByName(name)
    if not name or name == "" then return nil end
    local numTabs = GetNumGuildBankTabs()
    for i = 1, numTabs do
        local tabName = GetGuildBankTabInfo(i)
        if tabName == name then
            return i
        end
    end
    return nil
end

-- 현재 보고 있는 탭이 지정된 탭 중 어느 카테고리인지 판별 -> category, tabIndex
local function GetCurrentCategory()
    local currentTab = GetCurrentGuildBankTab()
    if not currentTab then return nil, nil end
    for category, tabName in pairs(db.tabNames) do
        if ResolveTabByName(tabName) == currentTab then
            return category, currentTab
        end
    end
    return nil, nil
end

-- =========================================================
-- 공용 순차 처리 큐 (한 번에 하나씩, 확인 없이 진행 / 창 닫히면 중단)
-- =========================================================
local ACTION_DELAY = 0.5
local queue = {}
local isProcessing = false

local function RunQueue(items, action, onDone)
    if isProcessing then
        print(PREFIX .. " 이미 작업이 진행 중입니다.")
        return
    end
    if #items == 0 then
        if onDone then onDone() end
        return
    end
    queue = items
    isProcessing = true

    local function step()
        if not GuildBankFrame or not GuildBankFrame:IsShown() then
            isProcessing = false
            queue = {}
            print(PREFIX .. " 길드은행 창이 닫혀 작업을 중단합니다.")
            return
        end
        if #queue == 0 then
            isProcessing = false
            if onDone then onDone() end
            return
        end
        local item = table.remove(queue, 1)
        action(item)
        C_Timer.After(ACTION_DELAY, step)
    end
    step()
end

-- =========================================================
-- 모두 넣기 (현재 보고 있는 탭에 해당하는 분류만)
-- =========================================================
local function DepositAll()
    if not GuildBankFrame or not GuildBankFrame:IsShown() then
        print(PREFIX .. " 길드은행 창이 열려있지 않습니다.")
        return
    end

    local category, tab = GetCurrentCategory()
    if not category then
        print(PREFIX .. " 지정된 탭에서만 사용할 수 있습니다.")
        return
    end

    local _, _, _, canDeposit = GetGuildBankTabInfo(tab)
    if not canDeposit then
        print(PREFIX .. " " .. tab .. "번 탭에 입고 권한이 없습니다.")
        return
    end

    local scanned = ScanBags()
    local items = scanned[category]

    if #items == 0 then
        print(PREFIX .. " 입고할 아이템이 없습니다.")
        return
    end

    -- 우클릭으로 은행에 넣는 것과 동일한 내장 함수를 사용
    -- (빈 칸 찾기/스택 병합/중복 아이템 처리를 블리자드가 알아서 처리)
    RunQueue(items, function(item)
        C_Container.UseContainerItem(item.bag, item.slot)
    end, function()
        print(PREFIX .. " 모두 넣기 완료.")
    end)
end

-- =========================================================
-- 모두 꺼내기 (현재 보고 있는 탭만)
-- =========================================================
local function WithdrawAll()
    if not GuildBankFrame or not GuildBankFrame:IsShown() then
        print(PREFIX .. " 길드은행 창이 열려있지 않습니다.")
        return
    end

    local category, tab = GetCurrentCategory()
    if not category then
        print(PREFIX .. " 지정된 탭에서만 사용할 수 있습니다.")
        return
    end

    local _, _, canView, _, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(tab)
    if not canView then
        print(PREFIX .. " " .. tab .. "번 탭을 볼 권한이 없습니다.")
        return
    end
    if numWithdrawals ~= -1 and remainingWithdrawals ~= nil and remainingWithdrawals <= 0 then
        print(PREFIX .. " " .. tab .. "번 탭은 오늘 인출 한도를 모두 사용했습니다.")
        return
    end

    local items = {}
    for slot = 1, GUILDBANK_SLOTS_PER_TAB do
        local texture = GetGuildBankItemInfo(tab, slot)
        if texture then
            table.insert(items, { tab = tab, slot = slot })
        end
    end

    if #items == 0 then
        print(PREFIX .. " 꺼낼 아이템이 없습니다.")
        return
    end

    RunQueue(items, function(item)
        AutoStoreGuildBankItem(item.tab, item.slot)
    end, function()
        print(PREFIX .. " 모두 꺼내기 완료.")
    end)
end

-- =========================================================
-- 길드은행 UI에 버튼 추가
-- =========================================================
local buttonsCreated = false
local depositBtn, withdrawBtn

local function UpdateButtonState()
    if not depositBtn or not withdrawBtn then return end
    local category = GetCurrentCategory()
    if category then
        depositBtn:Enable()
        withdrawBtn:Enable()
    else
        depositBtn:Disable()
        withdrawBtn:Disable()
    end
end

local function CreateButtons()
    if buttonsCreated then return end
    if not GuildBankFrame then return end
    buttonsCreated = true

    depositBtn = CreateFrame("Button", "GBAD_DepositAllButton", GuildBankFrame, "UIPanelButtonTemplate")
    depositBtn:SetSize(90, 22)
    depositBtn:SetPoint("BOTTOMLEFT", GuildBankFrame, "BOTTOMLEFT", 8, 30)
    depositBtn:SetText("모두 넣기")
    depositBtn:SetScript("OnClick", DepositAll)

    withdrawBtn = CreateFrame("Button", "GBAD_WithdrawAllButton", GuildBankFrame, "UIPanelButtonTemplate")
    withdrawBtn:SetSize(90, 22)
    withdrawBtn:SetPoint("LEFT", depositBtn, "RIGHT", 6, 0)
    withdrawBtn:SetText("모두 꺼내기")
    withdrawBtn:SetScript("OnClick", WithdrawAll)

    -- 탭을 전환할 때마다(초기 탭 선택 포함) 버튼 상태 갱신
    hooksecurefunc("SetCurrentGuildBankTab", UpdateButtonState)
    GuildBankFrame:HookScript("OnShow", UpdateButtonState)
    UpdateButtonState()
end

-- =========================================================
-- 이벤트 처리
-- =========================================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, ...)
    local addonName = ...
    if addonName == ADDON_NAME then
        InitDB()
    elseif addonName == "Blizzard_GuildBankUI" then
        CreateButtons()
    end
end)

-- 이미 로드되어 있는 경우(예: 리로드 후 은행이 열려있던 상태) 대비
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_GuildBankUI") then
    CreateButtons()
end

-- =========================================================
-- 슬래시 명령어
-- =========================================================
local CATEGORY_LABELS = {
    boe = "착귀(BoE)",
    cookfish = "요리낚시재료",
    mining = "채광재료",
    herb = "약초재료",
    clothleather = "천가죽재료",
}

SLASH_GUILDBANKAUTODEPOSIT1 = "/gbad"
SlashCmdList["GUILDBANKAUTODEPOSIT"] = function(msg)
    local raw = msg:trim()
    local cmd, arg = raw:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "tab" then
        local category, name = arg:match("^(%S*)%s*(.-)$")
        if db.tabNames[category] and name ~= "" then
            db.tabNames[category] = name
            print(PREFIX .. " " .. CATEGORY_LABELS[category] .. " 탭 이름을 '" .. name .. "'(으)로 설정했습니다.")
        else
            print(PREFIX .. " 사용법: /gbad tab <boe|cookfish|mining|herb|clothleather> <탭이름>")
        end

    elseif cmd == "deposit" then
        DepositAll()

    elseif cmd == "withdraw" then
        WithdrawAll()

    elseif cmd == "ignore" then
        local subcmd, subarg = arg:match("^(%S*)%s*(.-)$")
        if subcmd == "add" then
            local itemID = tonumber(subarg) or tonumber(subarg:match("item:(%d+)"))
            if itemID then
                db.ignore[itemID] = true
                print(PREFIX .. " 아이템 ID " .. itemID .. "을(를) 제외 목록에 추가했습니다.")
            else
                print(PREFIX .. " 사용법: /gbad ignore add <아이템ID 또는 아이템링크>")
            end
        elseif subcmd == "remove" then
            local itemID = tonumber(subarg) or tonumber(subarg:match("item:(%d+)"))
            if itemID and db.ignore[itemID] then
                db.ignore[itemID] = nil
                print(PREFIX .. " 아이템 ID " .. itemID .. "을(를) 제외 목록에서 제거했습니다.")
            else
                print(PREFIX .. " 제외 목록에 없는 아이템입니다.")
            end
        elseif subcmd == "list" then
            print(PREFIX .. " 제외 목록:")
            local any = false
            for itemID in pairs(db.ignore) do
                any = true
                local name = C_Item.GetItemInfo(itemID) or ("ID " .. itemID)
                print("  - " .. name)
            end
            if not any then print("  (없음)") end
        else
            print(PREFIX .. " 사용법: /gbad ignore add|remove|list [아이템ID]")
        end

    elseif cmd == "scan" then
        local category = GetCurrentCategory()
        if not category then
            print(PREFIX .. " 지정된 탭에서만 사용할 수 있습니다.")
            return
        end
        local scanned = ScanBags()
        local items = scanned[category]
        if #items == 0 then
            print(PREFIX .. " 대상 아이템이 없습니다.")
            return
        end
        for _, item in ipairs(items) do
            local name = C_Item.GetItemInfo(item.itemID) or ("ID " .. item.itemID)
            print(PREFIX .. " [가방 " .. item.bag .. "/" .. item.slot .. "] " .. name .. " x" .. item.count)
        end

    elseif cmd == "refresh" then
        UpdateButtonState()
        print(PREFIX .. " 버튼 상태를 수동으로 갱신했습니다.")

    elseif cmd == "tabinfo" then
        local currentTab = GetCurrentGuildBankTab()
        print(PREFIX .. " 디버그 정보")
        print("  GetCurrentGuildBankTab() = " .. tostring(currentTab))
        for category, name in pairs(db.tabNames) do
            print("  " .. CATEGORY_LABELS[category] .. " '" .. name .. "' -> 탭 " .. tostring(ResolveTabByName(name)))
        end
        local numTabs = GetNumGuildBankTabs()
        for i = 1, numTabs do
            print("  탭 " .. i .. ": " .. tostring(GetGuildBankTabInfo(i)))
        end

    elseif cmd == "status" then
        print(PREFIX .. " 상태")
        for category, name in pairs(db.tabNames) do
            print("  " .. CATEGORY_LABELS[category] .. ": " .. name)
        end
        local count = 0
        for _ in pairs(db.ignore) do count = count + 1 end
        print("  제외 아이템 수: " .. count)

    else
        print(PREFIX .. " 명령어 목록")
        print("  /gbad tab <boe|cookfish|mining|herb|clothleather> <이름> - 탭 이름 설정")
        print("  /gbad deposit - 모두 넣기 (버튼과 동일)")
        print("  /gbad withdraw - 모두 꺼내기 (버튼과 동일)")
        print("  /gbad scan - 현재 탭 기준으로 대상 아이템 미리보기")
        print("  /gbad ignore add <아이템ID|링크> - 제외 목록에 추가")
        print("  /gbad ignore remove <아이템ID> - 제외 목록에서 제거")
        print("  /gbad ignore list - 제외 목록 보기")
        print("  /gbad status - 현재 설정 확인")
        print("  /gbad tabinfo - 탭 매칭 디버그 정보")
    end
end