-- Achievement-style alerts adapted from Ompcraft (MIT, TechDufus).
WoWAI_Toasts = { queue = {}, seen = {}, order = {}, frames = {} }

function WoWAI_Toasts.Bind(ctx)
	WoWAI_Toasts.ctx = ctx
end

function WoWAI_Toasts.Enqueue(kind, chat, key)
	local self, ctx = WoWAI_Toasts, WoWAI_Toasts.ctx
	if not ctx or not ctx.db.settings.toasts or not chat then return end
	key = tostring(key or (kind .. ":" .. chat.id))
	if self.seen[key] then return end
	self.seen[key] = true; table.insert(self.order, key)
	if #self.order > 100 then self.seen[table.remove(self.order, 1)] = nil end
	if kind == "done" or kind == "error" then
		for i = #self.queue, 1, -1 do
			if self.queue[i].chatId == chat.id and self.queue[i].kind == "needs" then table.remove(self.queue, i) end
		end
	end
	if #self.queue >= 20 then table.remove(self.queue, 1) end
	table.insert(self.queue, { kind = kind, chatId = chat.id, name = chat.name, key = key })
	self.Pump()
end

function WoWAI_Toasts.Clear()
	local self = WoWAI_Toasts
	for i = #self.queue, 1, -1 do self.queue[i] = nil end
	for _, frame in ipairs(self.frames) do
		frame.active = false; frame.token = (frame.token or 0) + 1; frame:Hide()
	end
end

function WoWAI_Toasts.Pump()
	local self = WoWAI_Toasts
	if not self.ctx then return end
	if not self.ctx.db.settings.toasts then self.Clear(); return end
	if InCombatLockdown() then return end
	for i = 1, 3 do
		local f = self.frames[i]
		if not f then
			f = CreateFrame("Button", nil, UIParent)
			f:SetSize(300, 82); f:SetPoint("TOP", UIParent, "TOP", 0, -110 - (i - 1) * 86)
			f.bg = f:CreateTexture(nil, "BACKGROUND"); f.bg:SetAllPoints()
			if f.bg.SetAtlas then f.bg:SetAtlas("ui-achievement-alert-background", false) else f.bg:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Background") end
			f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal"); f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 50, -20)
			f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6); f.text:SetWidth(220); f.text:SetJustifyH("LEFT")
			f:SetScript("OnClick", function(button)
				local ctx = self.ctx
				if ctx.FindChat(button.chatId) then ctx.WoWAI.SwitchChat(button.chatId); ctx.WoWAI.Toggle(true) end
				button.active = false; button:Hide(); self.Pump()
			end)
			f:Hide(); self.frames[i] = f
		end
		if not f.active and #self.queue > 0 then
			local item = table.remove(self.queue, 1)
			f.active = true; f.chatId = item.chatId; f.token = (f.token or 0) + 1
			f.title:SetText(item.kind == "needs" and "Input needed" or item.kind == "error" and "Agent error" or "Reply ready")
			f.text:SetText(self.ctx.Display(item.name)); f:Show()
			local token = f.token
			C_Timer.After(7, function() if f.token == token then f.active = false; f:Hide(); self.Pump() end end)
		end
	end
end
