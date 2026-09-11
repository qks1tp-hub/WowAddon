local ADDON_NAME = "AutoSellRepair"

-- 기본 설정값
local defaults = {
    autoSell = true,
    autoRepair = true,
    useGuildFunds = false, -- 길드 자금 수리 기본 비활성화
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("MERCHANT_SHOW")

local totalSold = 0
local totalRepaired = 0

local function Print(msg)
    print("|cff33ff99[AutoSellRepair]|r " .. msg)
end

-- 회색템 자동 판매 (Blizzard 내장 "잡동사니 판매" API 사용, 10.1.5+)
local function SellGrayItems()
    if not AutoSellRepairDB.autoSell then return end
    if not C_MerchantFrame or not C_MerchantFrame.SellAllJunkItems then return end

    local junkCount = C_MerchantFrame.GetNumJunkItems and C_MerchantFrame.GetNumJunkItems() or 0
    if junkCount == 0 then return end
    if C_MerchantFrame.IsSellAllJunkEnabled and not C_MerchantFrame.IsSellAllJunkEnabled() then return end

    local goldBefore = GetMoney()
    C_MerchantFrame.SellAllJunkItems()

    -- 판매 완료 후 골드 변화량으로 수익 표시 (다음 프레임에 반영됨)
    C_Timer.After(0.2, function()
        local earned = GetMoney() - goldBefore
        if earned > 0 then
            totalSold = totalSold + earned
            Print(string.format("잡동사니 %d개 판매 (%s)", junkCount, GetCoinTextureString(earned)))
        end
    end)
end

-- 자동 수리
local function RepairAll()
    if not AutoSellRepairDB.autoRepair then return end
    if not CanMerchantRepair() then return end

    local cost, canRepair = GetRepairAllCost()
    if not canRepair or cost == 0 then return end

    -- 길드 자금 수리 가능 여부 확인
    local usedGuild = false
    if AutoSellRepairDB.useGuildFunds and CanGuildBankRepair and CanGuildBankRepair() then
        RepairAllItems(true)
        usedGuild = true
    else
        if GetMoney() < cost then
            Print("수리비가 부족합니다.")
            return
        end
        RepairAllItems(false)
    end

    totalRepaired = totalRepaired + cost
    Print(string.format("장비 수리 완료 (%s)%s", GetCoinTextureString(cost),
        usedGuild and " |cffaaaaaa[길드 자금]|r" or ""))
end

frame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON_NAME then
        AutoSellRepairDB = AutoSellRepairDB or defaults
        for k, v in pairs(defaults) do
            if AutoSellRepairDB[k] == nil then
                AutoSellRepairDB[k] = v
            end
        end
    elseif event == "MERCHANT_SHOW" then
        -- 판매 먼저, 그 다음 수리 (판 돈으로 수리 가능하도록)
        SellGrayItems()
        RepairAll()
    end
end)

-- 슬래시 명령어로 설정 토글
SLASH_AUTOSELLREPAIR1 = "/asr"
SlashCmdList["AUTOSELLREPAIR"] = function(msg)
    msg = msg:lower():trim()
    if msg == "sell" then
        AutoSellRepairDB.autoSell = not AutoSellRepairDB.autoSell
        Print("자동 판매: " .. (AutoSellRepairDB.autoSell and "켜짐" or "꺼짐"))
    elseif msg == "repair" then
        AutoSellRepairDB.autoRepair = not AutoSellRepairDB.autoRepair
        Print("자동 수리: " .. (AutoSellRepairDB.autoRepair and "켜짐" or "꺼짐"))
    elseif msg == "guild" then
        AutoSellRepairDB.useGuildFunds = not AutoSellRepairDB.useGuildFunds
        Print("길드 자금 사용: " .. (AutoSellRepairDB.useGuildFunds and "켜짐" or "꺼짐"))
    else
        Print("명령어: /asr sell (판매 토글), /asr repair (수리 토글), /asr guild (길드자금 토글)")
    end
end