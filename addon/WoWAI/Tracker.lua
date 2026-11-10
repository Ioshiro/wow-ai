-- Quest-style tracker adapted from Ompcraft (MIT, TechDufus).
WoWAI_Tracker = {}

function WoWAI_Tracker.Bind(ctx)
	local tracker, settings = WoWAI_Tracker, ctx.db.settings
	local frame = CreateFrame("Frame", "WoWAIMini", UIParent)
	ctx.ui.mini = frame
	frame:SetSize(260, 32)
	frame:SetPoint(settings.miniPoint or "TOPRIGHT", UIParent, settings.miniRelPoint or settings.miniPoint or "TOPRIGHT", settings.miniX or -24, settings.miniY or -250)
	frame:SetMovable(true); frame:SetClampedToScreen(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, relative, relPoint, x, y = self:GetPoint()
		settings.miniPoint, settings.miniRelPoint, settings.miniX, settings.miniY = point, relPoint, x, y
	end)
	frame:Hide()
	local header = CreateFrame("Button", nil, frame)
	header:SetPoint("TOPLEFT"); header:SetSize(230, 28)
	local headerArt = header:CreateTexture(nil, "BACKGROUND")
	headerArt:SetAllPoints()
	if headerArt.SetAtlas then headerArt:SetAtlas("ui-questtracker-primary-objective-header", false) else headerArt:SetColorTexture(0.08, 0.07, 0.04, 0.75) end
	local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", header, "LEFT", 4, 0); title:SetText("WoW AI  |cffffffff[-]|r")
	header:SetScript("OnClick", function() settings.trackerCollapsed = not settings.trackerCollapsed; tracker.Refresh() end)
	local config = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	config:SetSize(28, 22); config:SetPoint("TOPRIGHT"); config:SetText("...")
	config:SetScript("OnClick", function() ctx.WoWAI.ShowConfig() end)
	local rows = {}
	local markers = { needs = "Interface\\GossipFrame\\AvailableQuestIcon", unread = "Interface\\GossipFrame\\ActiveQuestIcon", error = "Interface\\GossipFrame\\AvailableQuestIcon" }
	function tracker.Refresh()
		frame:SetScale(settings.trackerScale)
		local groups = WoWAI_ViewModel.Build(ctx.db.chats, ctx.db.activeChat, ctx.run.interactions, ctx.db.liveAttached, ctx.run.bridgeCwd)
		local n, y, idle, omitted = 0, 30, 0, 0
		local function row(text, chatId, callback, state, progress)
			if y >= 520 then omitted = omitted + 1; return end
			n = n + 1
			local b = rows[n]
			if not b then
				b = CreateFrame("Button", nil, frame); b:SetSize(254, 19)
				b.wash = b:CreateTexture(nil, "BACKGROUND"); b.wash:SetAllPoints(); b.wash:SetColorTexture(0, 0, 0, 0.4)
				b.marker = b:CreateTexture(nil, "ARTWORK"); b.marker:SetSize(16, 16); b.marker:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -1)
				b.progress = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.progress:SetPoint("TOPLEFT", b, "TOPLEFT", 25, -19); b.progress:SetPoint("RIGHT", b, "RIGHT", -4, 0); b.progress:SetJustifyH("LEFT"); b.progress:SetWordWrap(false)
				b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				b.label:SetPoint("TOPLEFT", b, "TOPLEFT", 25, -2); b.label:SetPoint("RIGHT", b, "RIGHT", -4, 0); b.label:SetJustifyH("LEFT"); b.label:SetWordWrap(false)
				b:SetScript("OnClick", function(self) if self.action then self.action(self.chatId) end end)
				rows[n] = b
			end
			b:ClearAllPoints(); b:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y); b.label:SetText(text); b.chatId = chatId; b.action = callback
			b.marker:Hide()
			if state == "working" and b.marker.SetAtlas then
				b.marker:SetAtlas("SideInProgressquesticon", false); b.marker:SetVertexColor(1, 1, 1); b.marker:Show()
			elseif markers[state] then
				b.marker:SetTexture(markers[state]); b.marker:SetVertexColor(1, state == "error" and 0.2 or 1, state == "error" and 0.2 or 1); b.marker:Show()
			end
			local preview = progress and progress:gsub("[\r\n]+", " ") or ""
			b.progress:SetText(ctx.Display(preview)); b.progress:SetShown(preview ~= "")
			local height = preview ~= "" and 36 or 19
			b:SetHeight(height); b:Show(); y = y + height
		end
		if not settings.trackerCollapsed then
			for _, group in ipairs(groups) do
				local has = false
				for _, chat in ipairs(group.chats) do if chat.state ~= "idle" then has = true else idle = idle + 1 end end
				if has or settings.trackerIdleOpen then
					local name = group.folder:match("([^\\/]+)[\\/]*$") or "Default folder"
					row("|cffffd100" .. ctx.Display(name) .. "|r")
					for _, chat in ipairs(group.chats) do
						if chat.state ~= "idle" or settings.trackerIdleOpen then
							row(ctx.Display(chat.name), chat.id, function(id) ctx.WoWAI.SwitchChat(id); ctx.WoWAI.Toggle(true) end, chat.state, (chat.state == "working" or chat.state == "needs" or chat.state == "error") and chat.progress or "")
						end
					end
				end
			end
			if idle > 0 then row("|cffaaaaaa" .. (settings.trackerIdleOpen and "[-]" or "[+]") .. " Idle (" .. idle .. ")|r", nil, function() settings.trackerIdleOpen = not settings.trackerIdleOpen; tracker.Refresh() end) end
			if not ctx.WoWAI.IsConnected() then row("|cffff8080Bridge disconnected - click to reconnect|r", nil, ctx.WoWAI.Connect) end
		end
		if omitted > 0 then
			headerArt:SetAlpha(0.8)
			title:SetText("WoW AI  (+" .. omitted .. " hidden; open chat list)")
		else
			headerArt:SetAlpha(1)
			title:SetText(settings.trackerCollapsed and "WoW AI  [+]" or "WoW AI  [-]")
		end
		for i = n + 1, #rows do rows[i]:Hide() end
		frame:SetHeight(y + 4)
		tracker.CombatChanged()
	end
	function tracker.CombatChanged()
		local show = settings.tracker and settings.shown and (not settings.hideTrackerCombat or not InCombatLockdown())
		frame:SetShown(show and true or false)
	end
	tracker.frame, tracker.rows = frame, rows
	return tracker
end
