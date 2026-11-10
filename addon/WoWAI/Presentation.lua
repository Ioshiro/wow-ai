-- Window and interaction presentation. Bound to the current session at login.
WoWAI_Presentation = {}

function WoWAI_Presentation.Bind(ctx)
	local WoWAI, ui, db, run = ctx.WoWAI, ctx.ui, ctx.db, ctx.run
	local ActiveChat, FindChat, Display = ctx.ActiveChat, ctx.FindChat, ctx.Display
	local FolderName, ChatFolder, AgentName = ctx.FolderName, ctx.ChatFolder, ctx.AgentName
	local ChatAgent, ChatAgentName, ReplyAgentName = ctx.ChatAgent, ctx.ChatAgentName, ctx.ReplyAgentName
	local ActivityLine, SafeReload = ctx.ActivityLine, ctx.SafeReload
	local AddHistory, Wire, ToHex = ctx.AddHistory, ctx.Wire, ctx.ToHex
	local US = ctx.US
	local MAX_CHATS, STRIP_TRIES = ctx.MAX_CHATS, ctx.STRIP_TRIES
	local BACKDROP, ROLE_STYLE = WoWAI_Style.BACKDROP, WoWAI_Style.ROLE_STYLE

-- RENDERING
function WoWAI.UpdateStatus()
	if not ui.status then return end
	local c = ActiveChat()
	local mode = db.settings.mode
	local s
	if c and c.pendingId then
		if run.interactions[c.id] and run.interactions[c.id].ui then
			s = "Input needed - click Respond to view the request"
		else
		local id = c.pendingId
		local elapsed = run.sentAt and (GetTime() - run.sentAt) or 0
		local rec = run.outbound[id]
		if mode == "pixel" then
			if run.slotsMissing then
				s = "Reply slots not installed (run install-slots.js, restart WoW). Using reload instead: Enter or Refresh"
			elseif run.slotsExhausted then
				s = "Slot pool used up this session - next keypress reloads to free it"
			elseif run.pixelFailed then
				s = "Bridge didn't see #" .. id .. " after " .. STRIP_TRIES .. " tries - next keypress switches to the reload path (or /wow-ai reload)"
			elseif c.progress or (run.act and run.act[c.id] and run.act[c.id].count > 0) then
				s = ChatAgentName(c) .. " is working on #" .. id .. " - " .. ActivityLine(c)
			elseif rec and not rec.acked then
				s = "Sending #" .. id .. (rec.tries and rec.tries > 1 and (" (try " .. rec.tries .. "/" .. STRIP_TRIES .. ")") or "") .. "..."
				local state = WoWAI.BridgeState()
				if state == "down" then s = s .. " - bridge not seen lately, is the bridge running?" end
			else
				s = "Waiting for #" .. id .. " (checked " .. (run.polls or 0) .. "x)"
				if elapsed > 45 then
					s = s .. " - no sign of the bridge. Is the bridge running? /wow-ai resend"
				end
			end
		else
			s = "Waiting for reply #" .. id .. ". Enter or Refresh checks now"
			if db.settings.autoRefresh then
				s = s .. "; auto on next keypress after " .. db.settings.interval .. "s"
			end
		end
		end
    elseif c and c.liveStatus and db.liveAttached[c.id] then
        s = "Live " .. tostring(c.liveStatus) .. (c.liveText ~= "" and (": " .. c.liveText) or "")
    elseif not WoWAI.IsConnected() then
		if run.connectingAt and run.sendOnConnect then
			s = "Connecting to the bridge... your message goes out as soon as it answers"
		elseif run.connectingAt then
			s = "Connecting to the bridge..."
		elseif run.connectFailed then
			s = "No answer from the bridge. Is it running (npm start)? Connect tries again"
		elseif WoWAI.BridgeState() == "stale" then
			s = "Bridge not seen for a while - click Reconnect"
		else
			s = "Not connected - start the bridge, then click Connect"
		end
	elseif c and c.draft and c.draft ~= "" then
		s = "Reply arrived. Your draft is back in the box - Enter to send it"
	elseif run.restoring then
		s = "Connecting to the bridge..."
	else
		s = "Ready"
	end
	ui.status:SetText(s)
	run.statusText = s
	WoWAI.UpdateDot()
	WoWAI.UpdateConnect()
	if ui.title then
		local t = c and Display(c.name) or "WoW AI"
		local folder = FolderName(ChatFolder(c))
		if folder ~= "" then t = t .. "  |cff888888" .. Display(folder) .. "|r" end
		if c and c.agent and c.agent ~= "" then t = t .. "  |cff888888" .. AgentName(c.agent) .. "|r" end
		ui.title:SetText(t)
	end
	local cwdText
	if c and c.cwd ~= "" then
		cwdText = Display(c.cwd)
	elseif run.bridgeCwd then
		cwdText = Display(run.bridgeCwd) .. " (bridge default)"
	else
		cwdText = "(bridge default - start the bridge in a folder, or right-click the chat and pick Folder)"
	end
	local agentText
	if c and c.agent and c.agent ~= "" then
		agentText = AgentName(c.agent)
	elseif run.bridgeAgent then
		agentText = AgentName(run.bridgeAgent) .. " (bridge default)"
	else
		agentText = "(bridge default)"
	end
	ui.cwd:SetText("cwd: " .. cwdText .. "   agent: " .. agentText .. "   mode: " .. mode)
	if ui.resend then ui.resend:SetShown(c and c.pendingId ~= nil and mode == "pixel") end
	if ui.refresh then ui.refresh:SetShown(mode ~= "pixel" or run.slotsExhausted or run.slotsMissing or run.pixelFailed or false) end
	if ui.respond then ui.respond:SetShown(c and run.interactions[c.id] and run.interactions[c.id].ui ~= nil or false) end
	WoWAI.UpdateMini()
end

-- One message bubble: accent bar, colored label, timestamp, wrapped body.
local function GetBubble(i)
	local b = ui.bubbles[i]
	if b then return b end
	b = CreateFrame("Frame", nil, ui.content)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.accent = b:CreateTexture(nil, "BORDER")
	b.accent:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b.accent:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	b.accent:SetWidth(3)
	b.who = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.who:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -6)
	b.who:SetJustifyH("LEFT")
	b.when = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.when:SetPoint("TOPRIGHT", b, "TOPRIGHT", -8, -6)
	b.body = CreateFrame("Frame", nil, b)
	b.body:SetPoint("TOPLEFT", b.who, "BOTTOMLEFT", 0, -4)
	b.rows = {}
	b.allow = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
	b.allow:SetHeight(22)
	b.allow:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6)
	b.allow:SetScript("OnClick", function(self)
		WoWAI.Allow(self.chatId, self.rules)
	end)
	b.allow:Hide()
	b.macroBtns = {}
	-- FontStrings can't be selected, so a click opens the message in the copy box.
	b:EnableMouse(true)
	b:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and self.text and self.text ~= "" then WoWAI.ShowCopy(self.text) end
	end)
	ui.bubbles[i] = b
	return b
end

function WoWAI.Render()
	local c = ActiveChat()
	if ui.content and c then
		local width = ui.scroll:GetWidth()
		if not width or width < 80 then width = 400 end
		ui.content:SetWidth(width)
		local y, n = 0, 0
		local function Place(role, text, when, dim, denied, agent, macros)
			n = n + 1
			local b = GetBubble(n)
			local st = ROLE_STYLE[role] or ROLE_STYLE.system
			b:SetWidth(width)
			b.bg:SetColorTexture(st.bg[1], st.bg[2], st.bg[3], st.bg[4])
			b.accent:SetColorTexture(st.color[1], st.color[2], st.color[3], 0.9)
			b.who:SetText(st == ROLE_STYLE.assistant and ReplyAgentName(c, agent) or st.label)
			b.who:SetTextColor(st.color[1], st.color[2], st.color[3])
			b.when:SetText(when or "")
			b.body:SetWidth(width - 18)
			local h = 0
			local rendered = WoWAI_Markdown.Render(text or "")
			for i, row in ipairs(rendered) do
				local item = b.rows[i]
				if not item then
					item = CreateFrame("Frame", nil, b.body)
					item.band = item:CreateTexture(nil, "BACKGROUND"); item.band:SetAllPoints()
					item.text = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
					item.text:SetJustifyH("LEFT"); item.text:SetJustifyV("TOP"); item.text:SetWordWrap(true); item.text:SetNonSpaceWrap(true)
					b.rows[i] = item
				end
				item:ClearAllPoints(); item:SetPoint("TOPLEFT", b.body, "TOPLEFT", 0, -h); item:SetWidth(width - 18)
				local indent = row.kind == "li" and (math.max(0, (row.depth or 1) - 1) * 14 + 12) or row.kind == "quote" and 12 or row.kind == "code" and 8 or 0
				local font = row.kind == "h" and (QuestFontNormalLarge or GameFontNormalLarge) or row.kind == "code" and (GameFontHighlightSmall or ChatFontNormal) or (QuestFont or GameFontHighlight)
				item.text:SetFontObject(font); item.text:ClearAllPoints(); item.text:SetPoint("TOPLEFT", item, "TOPLEFT", indent, 0); item.text:SetWidth(math.max(20, width - 18 - indent))
				local prefix = row.kind == "li" and "• " or row.kind == "quote" and "│ " or ""
				item.text:SetText(prefix .. (row.text ~= "" and row.text or " "))
				if row.kind == "code" then item.text:SetTextColor(0.88, 0.9, 0.88); item.band:SetColorTexture(0.12, 0.10, 0.08, 0.85)
				elseif row.kind == "hr" then item.text:SetText(""); item.band:SetColorTexture(0.35, 0.25, 0.1, 0.55)
				else
					if row.kind == "h" then item.text:SetTextColor(0.35, 0.10, 0.02) elseif dim or row.kind == "quote" then item.text:SetTextColor(0.42, 0.34, 0.24) else item.text:SetTextColor(0.18, 0.12, 0.06) end
					if row.kind == "tr" and i % 2 == 0 then item.band:SetColorTexture(0.35, 0.25, 0.1, 0.1) else item.band:SetColorTexture(0, 0, 0, 0) end
				end
				local height = row.kind == "gap" and 6 or row.kind == "hr" and 2 or math.max(14, item.text:GetStringHeight() or 14) + 3
				item:SetHeight(height); item:Show(); h = h + height
			end
			for i = #rendered + 1, #b.rows do b.rows[i]:Hide() end
			h = math.max(h, 1); b.body:SetHeight(h)
			local extra = 0
			if denied then
				local label = "Allow " .. table.concat(denied, ", ") .. " & retry"
				b.allow:SetText(label)
				b.allow:SetWidth(math.min(width - 24, math.max(160, b.allow:GetFontString():GetStringWidth() + 30)))
				b.allow.chatId = c.id
				b.allow.rules = denied
				b.allow:Show()
				extra = 28
			else
				b.allow:Hide()
			end
			-- One button per macro the agent handed over.
			local shownMacros = 0
			for k, m in ipairs(macros or {}) do
				local mb = b.macroBtns[k]
				if not mb then
					mb = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
					mb:SetHeight(22)
					mb:SetScript("OnClick", function(self) WoWAI.InstallMacro(self.macro) end)
					mb:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:AddLine(Display(self.macro.name))
						GameTooltip:AddLine(Display(self.macro.body), 1, 1, 1, true)
						GameTooltip:Show()
					end)
					mb:SetScript("OnLeave", function() GameTooltip:Hide() end)
					b.macroBtns[k] = mb
				end
				mb.macro = m
				mb:SetText(WoWAI.MacroLabel(m))
				mb:SetWidth(math.min(width - 24, math.max(160, mb:GetFontString():GetStringWidth() + 30)))
				mb:ClearAllPoints()
				mb:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6 - extra)
				mb:Show()
				extra = extra + 28
				shownMacros = k
			end
			for k = shownMacros + 1, #b.macroBtns do b.macroBtns[k]:Hide() end
			b:SetHeight(6 + 12 + 4 + h + 8 + extra)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, -y)
			b.text = text
			b:Show()
			y = y + b:GetHeight() + 6
		end
		local last = #c.history
		local first = 1
		if not db.settings.fullHistory then
			first = math.max(1, last)
			for i = last, 1, -1 do
				if c.history[i].role == "assistant" or c.history[i].role == "system" then first = i; break end
			end
		end
		for i = first, last do
			local m = c.history[i]
			local denied = (i == last and not c.pendingId and type(m.denied) == "table" and #m.denied > 0) and m.denied or nil
			Place(m.role, m.text, m.t and date("%H:%M", m.t) or "", false, denied, m.agent, m.macros)
		end
		if c.pendingId then
			local p = c.progress
			local head = "working... " .. ActivityLine(c)
			if run.statusText and run.statusText ~= "" then head = head .. "\n" .. run.statusText end
			Place("assistant", (p and p ~= "") and (head .. "\n\n" .. p) or head, "", true, nil, ChatAgent(c))
		elseif #c.history == 0 then
			if run.restoring then
				Place("system", "Connecting to the bridge and restoring your chats...", "", true)
			elseif not WoWAI.IsConnected() then
				Place("system", "Not connected to the bridge. Start it (npm start in the wow-ai folder, or wow-ai in your project), then click Connect below.", "", true)
			else
				Place("system", "Click the box below and type to start. Shift-click an item, spell or quest to link it into your message. /wow-ai help lists the commands; /ai <text> and /r work from the game chat too.", "", true)
			end
		end
		for i = n + 1, #ui.bubbles do
			ui.bubbles[i]:Hide()
		end
		ui.content:SetHeight(math.max(y, 1))
		C_Timer.After(0.05, function()
			if ui.scroll then
				ui.scroll:SetVerticalScroll(ui.scroll:GetVerticalScrollRange())
			end
		end)
	end
	WoWAI.UpdateStatus()
	WoWAI.RenderChatList()
end

-- Copy box (/wow-ai copy): a selectable EditBox with the last reply pre-highlighted for Ctrl+C.
function WoWAI.ShowCopy(text)
	if not ui.copy then
		local cf = CreateFrame("Frame", "WoWAICopy", UIParent, "BackdropTemplate")
		cf:SetSize(560, 320)
		cf:SetPoint("CENTER")
		cf:SetFrameStrata("FULLSCREEN_DIALOG")
		cf:SetMovable(true)
		cf:SetClampedToScreen(true)
		cf:EnableMouse(true)
		cf:RegisterForDrag("LeftButton")
		cf:SetScript("OnDragStart", cf.StartMoving)
		cf:SetScript("OnDragStop", cf.StopMovingOrSizing)
		cf:SetBackdrop(BACKDROP)
		cf:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
		cf:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
		tinsert(UISpecialFrames, "WoWAICopy")

		local t = cf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -12)
		t:SetText("Text is selected - press Ctrl+C, then Esc")

		local x = CreateFrame("Button", nil, cf, "UIPanelCloseButton")
		x:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -4, -4)

		local sc = CreateFrame("ScrollFrame", "WoWAICopyScroll", cf, "UIPanelScrollFrameTemplate")
		sc:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -36)
		sc:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -32, 14)
		local eb = CreateFrame("EditBox", "WoWAICopyBox", sc)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal)
		eb:SetMaxLetters(0)
		eb:SetSize(500, 260)
		eb:SetScript("OnEscapePressed", function() cf:Hide() end)
		sc:SetScrollChild(eb)
		sc:HookScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)
		ui.copy, ui.copyBox = cf, eb
	end
	ui.copyBox:SetText(text)
	ui.copy:Show()
	ui.copyBox:SetFocus()
	ui.copyBox:HighlightText()
end

function WoWAI.RenderChatList()
	if not ui.chatButtons then return end
	for i, btn in ipairs(ui.chatButtons) do
		local c = db.chats[i]
		if c then
			local label = Display(c.name)
			local folder = FolderName(ChatFolder(c))
			if folder ~= "" and folder:lower() ~= c.name:lower() then
				label = label .. " |cff888888" .. Display(folder) .. "|r"
			end
			if c.agent and c.agent ~= "" then
				label = label .. " |cff888888" .. AgentName(c.agent) .. "|r"
			end
			if run.interactions[c.id] and run.interactions[c.id].ui then
				label = label .. " |cffffd100[Input]|r"
			elseif c.pendingId then
				label = label .. " |cffffd100...|r"
			elseif (c.unread or 0) > 0 then
				label = label .. " |cff55ff55(" .. c.unread .. ")|r"
			end
			btn.label:SetText(label)
			btn.chatId = c.id
			btn.selected:SetShown(c.id == db.activeChat)
			btn:Show()
		else
			btn:Hide()
		end
	end
end

function WoWAI.UpdateMini()
	if WoWAI_Tracker.frame then WoWAI_Tracker.Refresh() end
end

-- WINDOWS
local function MakeButton(parent, label, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end
function WoWAI.CloseInteraction(chatId)
	if ui.interaction and (not chatId or ui.interaction.chatId == chatId) then ui.interaction:Hide() end
end

function WoWAI.ShowInteraction()
	local c = ActiveChat()
	local live = c and run.interactions[c.id]
	local request = live and live.ui
	if not request or live.submitted == request.id then return end
	if not ui.interaction then
		local f = CreateFrame("Frame", "WoWAIInteraction", UIParent, "BackdropTemplate")
		f:SetSize(560, 430); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG")
		f:SetMovable(true); f:SetClampedToScreen(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
		f:SetBackdrop(BACKDROP); f:SetBackdropColor(0.20, 0.14, 0.08, 0.98); f:SetBackdropBorderColor(0.65, 0.48, 0.22, 1)
		local paper = f:CreateTexture(nil, "BACKGROUND", nil, 1)
		paper:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -36); paper:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 44)
		if paper.SetAtlas then paper:SetAtlas("QuestBG-Parchment", false) else paper:SetColorTexture(0.84, 0.77, 0.62, 1) end
		tinsert(UISpecialFrames, "WoWAIInteraction")
		f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -14); f.title:SetPoint("RIGHT", f, "RIGHT", -36, 0); f.title:SetJustifyH("LEFT")
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
		close:SetScript("OnClick", function() f:Hide() end)
		local scroll = CreateFrame("ScrollFrame", "WoWAIInteractionScroll", f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42); scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 50)
		f.body = CreateFrame("Frame", nil, scroll); f.body:SetSize(500, 1); scroll:SetScrollChild(f.body); f.rows = {}
		local cancel = MakeButton(f, "Cancel request", 120, function() WoWAI.SubmitInteraction("cancel") end)
		cancel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
		local submit = MakeButton(f, "Submit", 100, function() WoWAI.SubmitInteraction() end)
		submit:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)
		f:Hide(); ui.interaction = f
	end
	local f = ui.interaction
	if f.chatId ~= c.id or f.token ~= request.id then f.state = {}; f.chatId = c.id; f.token = request.id end
	f.title:SetText(Display(request.title or "Input requested"))
	for _, item in ipairs(f.rows) do item:Hide() end
	local index, y = 0, 0
	local function row(kind, height)
		index = index + 1
		local item = f.rows[index]
		if not item or item.kind ~= kind then
			if item then item:Hide() end
			item = CreateFrame(kind, nil, f.body, kind == "Button" and "UIPanelButtonTemplate" or nil)
			item.kind = kind; f.rows[index] = item
		end
		item:ClearAllPoints(); item:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, -y); item:SetSize(490, height); item:Show(); y = y + height + 6
		return item
	end
	local function label(text)
		local item = row("Frame", 1)
		if not item.label then item.label = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); item.label:SetPoint("TOPLEFT"); item.label:SetWidth(485); item.label:SetJustifyH("LEFT"); item.label:SetTextColor(0.18, 0.12, 0.06) end
		item.label:SetText(Display(text)); local h = math.max(18, item.label:GetStringHeight() + 4); item:SetHeight(h); y = y + h - 1
	end
	local function input(key, value, multiline)
		local e = row("EditBox", multiline and 100 or 28)
		if not e.bg then e.bg = e:CreateTexture(nil, "BACKGROUND"); e.bg:SetAllPoints(); e.bg:SetColorTexture(0, 0, 0, 0.55) end
		e:SetFontObject(ChatFontNormal); e:SetAutoFocus(false); e:SetMultiLine(multiline and true or false); e:SetMaxLetters(0)
		e:SetText(f.state[key] or tostring(value or "")); e:SetScript("OnTextChanged", function(self) f.state[key] = self:GetText() end)
		e:SetScript("OnEscapePressed", function() f:Hide() end)
	end
	local function options(list, key, multi)
		for i, opt in ipairs(list or {}) do
			local n, option = i, opt
			local b = row("Button", 32)
			local selected = f.state[key] and f.state[key][n]
			b:SetText((selected and "[x] " or "[ ] ") .. Display(option.label or ""))
			local font = b:GetFontString()
			if font and font.SetWordWrap then
				font:SetWordWrap(true); font:SetWidth(470)
				local height = math.max(32, font:GetStringHeight() + 12)
				b:SetHeight(height); y = y + height - 32
			end
			b:SetScript("OnClick", function()
				f.state[key] = f.state[key] or {}
				local was = f.state[key][n]
				if not multi then for k in pairs(f.state[key]) do f.state[key][k] = nil end end
				f.state[key][n] = not was
				WoWAI.ShowInteraction()
			end)
			if option.description and option.description ~= "" then label(option.description) end
		end
	end
	if request.message and request.message ~= "" then label(request.message) end
	if request.method == "select" then options(request.options, "choice", false)
	elseif request.method == "confirm" then options({ { label = "Yes" }, { label = "No" } }, "choice", false)
	elseif request.method == "input" or request.method == "editor" then input("value", request.value, request.method == "editor")
	elseif request.method == "ask" then
		for i, q in ipairs(request.questions or {}) do
			label((q.header and q.header ~= "" and (q.header .. ": ") or "") .. tostring(q.question or ""))
			options(q.options, "q" .. i, q.multi)
			label("Custom answer (optional)"); input("custom" .. i, "", false)
		end
	else label("Unsupported request type. Cancel the request or wait for the agent.") end
	f.body:SetHeight(math.max(1, y)); f:Show()
end

function WoWAI.SubmitInteraction(action)
	local f, c = ui.interaction, ActiveChat()
	local live = c and run.interactions[c.id]
	local r = live and live.ui
	if not f or not r or f.chatId ~= c.id or f.token ~= r.id or live.submitted == r.id then return end
	local fields = { Wire(r.id), action or r.method }
	if not action then
		if r.method == "select" or r.method == "confirm" then
			local chosen
			for i in pairs(f.state.choice or {}) do if f.state.choice[i] then chosen = i; break end end
			if not chosen then return end
			table.insert(fields, r.method == "confirm" and (chosen == 1 and "true" or "false") or tostring(chosen))
		elseif r.method == "input" or r.method == "editor" then
			fields[2] = "input"; table.insert(fields, Wire(f.state.value or r.value or ""))
		elseif r.method == "ask" then
			for i, q in ipairs(r.questions or {}) do
				local selected = {}
				for n = 1, #(q.options or {}) do if f.state["q" .. i] and f.state["q" .. i][n] then table.insert(selected, tostring(n)) end end
				local custom = Wire(f.state["custom" .. i] or "")
				if not q.multi and #selected > 0 and custom ~= "" then
					AddHistory(c, "system", "Choose an option or enter a custom answer, not both.")
					return
				end
				if not q.multi and #selected == 0 and custom == "" then return end
				table.insert(fields, table.concat(selected, ",") .. ":" .. ToHex(custom))
			end
		else return end
	else table.insert(fields, "") end
	if WoWAI.SendControl(c, "ui", table.concat(fields, US)) then live.submitted = r.id; f:Hide(); WoWAI.Render() end
end

local PANEL_W = 150

local function BuildUI()
	if ui.frame then return end
	local s = db.settings

	local f = CreateFrame("Frame", "WoWAIFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(s.width, s.height)
	if s.point then
		f:SetPoint(s.point, UIParent, s.relPoint or s.point, s.x or 0, s.y or 0)
	else
		f:SetPoint("CENTER")
	end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetClampedToScreen(true)
	f:SetResizeBounds(560, 300)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
	end)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
	f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	f:Hide()
	tinsert(UISpecialFrames, "WoWAIFrame")
	local paper = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	paper:SetPoint("TOPLEFT", f, "TOPLEFT", 170, -52)
	paper:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 105)
	if paper.SetAtlas then paper:SetAtlas("QuestBG-Parchment", false) else paper:SetColorTexture(0.84, 0.77, 0.62, 1) end
	local history = MakeButton(f, "Full history", 100, function(self)
		s.fullHistory = not s.fullHistory
		self:SetText(s.fullHistory and "Latest reply" or "Full history")
		WoWAI.Render()
	end)
	history:SetPoint("TOPRIGHT", f, "TOPRIGHT", -140, -25)
	history:SetText(s.fullHistory and "Latest reply" or "Full history")
	local settingsButton = MakeButton(f, "Settings", 70, function() WoWAI.ShowConfig() end)
	settingsButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, -25)

	-- Status light: green = bridge seen recently, yellow = stale, red = gone.
	local function MakeDot(parent)
		local holder = CreateFrame("Frame", nil, parent)
		holder:SetSize(16, 16)
		local dot = holder:CreateTexture(nil, "OVERLAY")
		dot:SetAllPoints()
		dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
		holder:EnableMouse(true)
		holder:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(dot.tip or "Bridge status", 0.9, 0.9, 0.9, 1, true)
			GameTooltip:Show()
		end)
		holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return holder, dot
	end

	local dotHolder, dot = MakeDot(f)
	dotHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -16)
	ui.dot = dot

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("LEFT", dotHolder, "RIGHT", 6, 0)
	title:SetText("WoW AI")
	ui.title = title

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
	status:SetPoint("RIGHT", f, "RIGHT", -60, 0)
	status:SetJustifyH("LEFT")
	ui.status = status
	local respond = MakeButton(f, "Respond", 80, function() WoWAI.ShowInteraction() end)
	respond:SetPoint("TOPRIGHT", f, "TOPRIGHT", -48, -52)
	respond:Hide(); ui.respond = respond

	-- Minimize button in the corner where a close X would be: this window is never
	-- closed from here, only collapsed to the mini bar (Esc does the same, see OnHide).
	-- The mini bar's own X is the one that hides everything.
	local mini
	if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("RedButton-MiniCondense") then
		-- Blizzard's own minimize button: the close button's chrome with a "condense" glyph.
		local ok, b = pcall(CreateFrame, "Button", nil, f, "UIPanelHideButtonNoScripts")
		if ok and b then mini = b end
	end
	if not mini then
		-- Older art: draw a dash on a plain button.
		mini = CreateFrame("Button", nil, f)
		mini:SetSize(24, 24)
		local dash = mini:CreateTexture(nil, "ARTWORK")
		dash:SetSize(10, 2)
		dash:SetPoint("CENTER", mini, "CENTER", 0, -3)
		dash:SetColorTexture(0.9, 0.9, 0.9, 1)
		local hl = mini:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.15)
	end
	mini:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
	mini:SetScript("OnClick", function() WoWAI.Minimize(true) end)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Minimize to the small bar  (Esc)")
		GameTooltip:AddLine("The agent keeps working; the bar shows when a reply lands.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Esc (via UISpecialFrames) just calls Hide(); treat that as a minimize unless
	-- we're hiding on purpose. Ignore hides caused by the whole UI going away.
	f:SetScript("OnHide", function()
		if ui.quitting then
			ui.quitting = nil
			return
		end
		if not db or not db.settings.shown or not UIParent:IsShown() then return end
		db.settings.minimized = true
		if ui.mini then WoWAI_Tracker.CombatChanged() end
		WoWAI.UpdateMini()
	end)

	-- Left panel: chat list
	local panel = CreateFrame("Frame", nil, f, "BackdropTemplate")
	panel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -52)
	panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 50)
	panel:SetWidth(PANEL_W)
	panel:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0, 0, 0, 0.4)
	panel:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	local newBtn = MakeButton(panel, "+ New chat", PANEL_W - 16, function() WoWAI.NewChat() end)
	newBtn:SetPoint("TOP", panel, "TOP", 0, -8)

	-- Per-chat menu: Rename, Folder and Agent, opened by right-clicking a chat
	-- row. A plain frame of our own rather than a Blizzard dropdown, so it looks
	-- the same on every client.
	local menu = CreateFrame("Frame", "WoWAIChatMenu", f, "BackdropTemplate")
	menu:SetSize(110, 4 * 20 + 12)
	menu:SetFrameStrata("TOOLTIP")
	menu:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	menu:SetBackdropColor(0.08, 0.08, 0.1, 0.97)
	menu:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	menu:EnableMouse(true)
	menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -8)
	menu.title:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
	menu.title:SetJustifyH("LEFT")
	menu.title:SetWordWrap(false)
	local function MenuItem(label, order, onClick)
		local it = CreateFrame("Button", nil, menu)
		it:SetSize(110 - 12, 20)
		it:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - order * 20)
		local hl = it:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.12)
		it.label = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		it.label:SetPoint("LEFT", it, "LEFT", 6, 0)
		it.label:SetText(label)
		it:SetScript("OnClick", function()
			menu:Hide()
			onClick(menu.chatId)
		end)
		return it
	end
	MenuItem("Rename...", 1, WoWAI.RenamePrompt)
	MenuItem("Folder...", 2, WoWAI.FolderPrompt)
	MenuItem("Agent...", 3, WoWAI.AgentPrompt)
	-- Close once the mouse has wandered away from the menu and the row it came from.
	menu:SetScript("OnUpdate", function(self, dt)
		if not MouseIsOver then return end
		if MouseIsOver(self) or (self.owner and MouseIsOver(self.owner)) then
			self.away = 0
		else
			self.away = (self.away or 0) + dt
			if self.away > 0.5 then self:Hide() end
		end
	end)
	menu:Hide()
	ui.chatMenu = menu

	function WoWAI.ShowChatMenu(chatId, anchor)
		local c = FindChat(chatId)
		if not c then return end
		if menu:IsShown() and menu.chatId == chatId then
			menu:Hide()
			return
		end
		menu.chatId = chatId
		menu.owner = anchor
		menu.away = 0
		menu.title:SetText(Display(c.name))
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, 2)
		menu:Show()
	end

	ui.chatButtons = {}
	for i = 1, MAX_CHATS do
		local b = CreateFrame("Button", nil, panel)
		b:SetSize(PANEL_W - 16, 20)
		b:SetPoint("TOP", newBtn, "BOTTOM", 0, -6 - (i - 1) * 21)
		b.selected = b:CreateTexture(nil, "BACKGROUND")
		b.selected:SetAllPoints()
		b.selected:SetColorTexture(1, 1, 1, 0.12)
		b.selected:Hide()
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)

		-- Trash can: delete this chat (asks first). Blizzard's red delete button
		-- where the client has it, a plain X elsewhere.
		b.del = CreateFrame("Button", nil, b)
		b.del:SetSize(16, 16)
		b.del:SetPoint("RIGHT", b, "RIGHT", -2, 0)
		if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("128-RedButton-Delete") then
			b.del:SetNormalAtlas("128-RedButton-Delete")
			b.del:SetPushedAtlas("128-RedButton-Delete-Pressed")
			b.del:SetHighlightAtlas("128-RedButton-Delete-Highlight")
		else
			b.del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
			b.del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
		end
		b.del:SetAlpha(0.6)
		b.del:SetScript("OnClick", function() WoWAI.ConfirmDelete(b.chatId) end)
		b.del:SetScript("OnEnter", function(self)
			self:SetAlpha(1)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Delete this chat")
			GameTooltip:Show()
		end)
		b.del:SetScript("OnLeave", function(self)
			self:SetAlpha(0.6)
			GameTooltip:Hide()
		end)

		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", b, "LEFT", 6, 0)
		b.label:SetPoint("RIGHT", b.del, "LEFT", -4, 0)
		b.label:SetJustifyH("LEFT")
		b.label:SetWordWrap(false)
		-- Left-click switches to the chat; right-click opens its menu (Rename,
		-- Folder, Agent). A second right-click on the same row closes the menu again.
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				WoWAI.ShowChatMenu(self.chatId, self)
			else
				WoWAI.SwitchChat(self.chatId)
			end
		end)
		b:SetScript("OnDoubleClick", function(self)
			WoWAI.SwitchChat(self.chatId)
			WoWAI.RenamePrompt(self.chatId)
		end)
		b:Hide()
		ui.chatButtons[i] = b
	end

	-- Transcript: a scrolling stack of message bubbles
	local scroll = CreateFrame("ScrollFrame", "WoWAIScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 110)
	ui.scroll = scroll

	local content = CreateFrame("Frame", "WoWAIContent", scroll)
	content:SetSize(500, 1)
	scroll:SetScrollChild(content)
	ui.content = content
	ui.bubbles = {}
	scroll:HookScript("OnSizeChanged", function(self, w, h)
		if ui.frame:IsShown() then WoWAI.Render() end
	end)

	-- Input box, with Send docked at its right end like a messaging app.
	local SEND_W = 84
	local inputBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
	inputBg:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 8, 0)
	inputBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14 - SEND_W - 6, 50)
	inputBg:SetHeight(54)
	inputBg:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	inputBg:SetBackdropColor(0, 0, 0, 0.6)
	inputBg:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

	local inScroll = CreateFrame("ScrollFrame", "WoWAIInputScroll", inputBg, "UIPanelScrollFrameTemplate")
	inScroll:SetPoint("TOPLEFT", inputBg, "TOPLEFT", 8, -6)
	inScroll:SetPoint("BOTTOMRIGHT", inputBg, "BOTTOMRIGHT", -24, 6)

	local input = CreateFrame("EditBox", "WoWAIInput", inScroll)
	input:SetMultiLine(true)
	input:SetAutoFocus(false)
	input:SetFontObject(ChatFontNormal)
	input:SetMaxLetters(0)
	input:SetSize(500, 40)
	input:SetScript("OnEnterPressed", function() WoWAI.SendFromInput() end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	inScroll:SetScrollChild(input)
	inScroll:HookScript("OnSizeChanged", function(self, w, h)
		input:SetWidth(w)
	end)
	inputBg:SetScript("OnMouseDown", function() input:SetFocus() end)
	ui.input = input

	-- Send sits to the right of the input box, vertically centred on it.
	local send = MakeButton(f, "Send", SEND_W, WoWAI.SendFromInput)
	send:SetHeight(30)
	send:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	ui.send = send

	-- Connect stands in for Send until the bridge has been seen (see UpdateConnect).
	local connect = MakeButton(f, "Connect", SEND_W, WoWAI.Connect)
	connect:SetHeight(30)
	connect:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	connect:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Connect to the bridge")
		GameTooltip:AddLine("The bridge must be running on this PC (npm start in wow-ai, or wow-ai in your project). The light turns green once it answers.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	connect:SetScript("OnLeave", function() GameTooltip:Hide() end)
	connect:Hide()
	ui.connect = connect

	-- Reload is the fallback transport's button; it sits apart on the right and
	-- only shows when a reload would do something (see UpdateStatus).
	local refresh = MakeButton(f, "Reload", 70, function() SafeReload() end)
	refresh:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 16)
	refresh:Hide()
	ui.refresh = refresh

	-- Bottom row: Clear, plus Resend while a message is in flight. Rename, Folder
	-- and Delete live on each chat row in the left panel.
	local clear = MakeButton(f, "Clear", 60, function()
		local c = ActiveChat()
		if c then wipe(c.history) end
		WoWAI.Render()
	end)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 16)

	local resend = MakeButton(f, "Resend", 70, WoWAI.Resend)
	resend:SetPoint("LEFT", clear, "RIGHT", 6, 0)
	resend:Hide()
	ui.resend = resend

	-- A named, always-present button so a keybinding can click it (see /wow-ai bind).
	local hotkey = CreateFrame("Button", "WoWAIRefreshButton", UIParent)
	hotkey:SetSize(1, 1)
	hotkey:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
	hotkey:SetScript("OnClick", function()
		local c = ActiveChat()
		if c and c.pendingId then
			WoWAI.Send("")
		else
			WoWAI.Toggle()
		end
	end)

	local cwd = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	cwd:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 4)
	cwd:SetPoint("RIGHT", f, "RIGHT", -30, 0)
	cwd:SetJustifyH("LEFT")
	cwd:SetWordWrap(false)
	ui.cwd = cwd

	-- Resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		s.width, s.height = f:GetSize()
	end)

	WoWAI_Tracker.Bind(ctx)
	function WoWAI.ShowConfig()
		if not ui.config then
			local config = CreateFrame("Frame", "WoWAIConfig", UIParent, "BackdropTemplate")
			config:SetSize(300, 220); config:SetPoint("CENTER"); config:SetFrameStrata("DIALOG")
			config:SetBackdrop(BACKDROP); config:SetBackdropColor(0.15, 0.1, 0.06, 0.98); config:SetBackdropBorderColor(0.65, 0.48, 0.22, 1)
			tinsert(UISpecialFrames, "WoWAIConfig")
			local title = config:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
			title:SetPoint("TOPLEFT", config, "TOPLEFT", 16, -14); title:SetText("WoW AI settings")
			local close = CreateFrame("Button", nil, config, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", config, "TOPRIGHT", -4, -4)
			local function toggle(key, label, y)
				local b = MakeButton(config, "", 230, function(self)
					s[key] = not s[key]; self:SetText(label .. (s[key] and ": on" or ": off")); WoWAI.UpdateMini()
					if key == "toasts" and not s[key] then WoWAI_Toasts.Clear() end
				end)
				b:SetPoint("TOPLEFT", config, "TOPLEFT", 20, y); b:SetText(label .. (s[key] and ": on" or ": off"))
			end
			toggle("tracker", "Tracker", -48); toggle("toasts", "Notifications", -78); toggle("hideTrackerCombat", "Hide tracker in combat", -108)
			local scale = MakeButton(config, "", 230, function(self)
				s.trackerScale = s.trackerScale >= 1.4 and 0.6 or math.floor((s.trackerScale + 0.1) * 10 + 0.5) / 10
				self:SetText("Tracker scale: " .. s.trackerScale); WoWAI.UpdateMini()
			end)
			scale:SetPoint("TOPLEFT", config, "TOPLEFT", 20, -138); scale:SetText("Tracker scale: " .. s.trackerScale)
			config:Hide(); ui.config = config
		end
		ui.config:SetShown(not ui.config:IsShown())
	end
	WoWAI_Toasts.Bind(ctx)
end

function WoWAI.Toggle(show)
	if not ui.frame then return end
	if show == nil then show = not ui.frame:IsShown() end
	if show then
		db.settings.minimized = false
		local c = ActiveChat()
		if c then c.unread = 0 end
	end
	if ui.mini then WoWAI_Tracker.CombatChanged() end
	if not show then WoWAI.CloseInteraction() end
	if not show then ui.quitting = true end
	ui.frame:SetShown(show)
	ui.quitting = nil
	db.settings.shown = show
	if show then
		WoWAI.Render()
		-- No auto-focus: the game keeps the keyboard until you click the box.
		-- No automatic hello either: if the bridge hasn't been seen, the panel
		-- shows Connect in place of Send and waits for a click.
	end
	WoWAI.UpdateMini()
end

function WoWAI.Minimize(mini)
	if not ui.frame then return end
	if mini == nil then mini = not db.settings.minimized end
	if mini then
		db.settings.minimized = true
		db.settings.shown = true
		ui.frame:Hide() -- OnHide shows the mini bar
		if ui.mini then WoWAI_Tracker.CombatChanged() end
		WoWAI.UpdateMini()
	else
		WoWAI.Toggle(true)
	end
end

	return BuildUI
end
