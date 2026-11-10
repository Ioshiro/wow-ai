-- Pure derivation of tracker rows from the existing chat/session state.
WoWAI_ViewModel = {}

function WoWAI_ViewModel.Build(chats, activeId, interactions, liveAttached, bridgeCwd)
	local groups, byFolder = {}, {}
	for _, chat in ipairs(chats or {}) do
		local live = interactions and interactions[chat.id]
		local state
		if live and live.ui and live.submitted ~= live.ui.id then state = "needs"
		elseif liveAttached and liveAttached[chat.id] and (chat.liveStatus == "needs" or chat.liveStatus == "input" or chat.liveStatus == "waiting_input") then state = "needs"
		elseif chat.pendingId or (liveAttached and liveAttached[chat.id] and chat.liveStatus == "working") then state = "working"
		elseif (liveAttached and liveAttached[chat.id] and (chat.liveStatus == "error" or chat.liveStatus == "failed" or chat.liveStatus == "disconnected")) or chat.lastError then state = "error"
		elseif (chat.unread or 0) > 0 then state = "unread"
		else state = "idle" end
		local folder = chat.cwd and chat.cwd ~= "" and chat.cwd or bridgeCwd or ""
		local group = byFolder[folder]
		if not group then
			group = { folder = folder, chats = {} }
			byFolder[folder] = group
			table.insert(groups, group)
		end
		table.insert(group.chats, { id = chat.id, name = chat.name, state = state, selected = chat.id == activeId, unread = chat.unread or 0, canRespond = state == "needs" and live and live.ui ~= nil or false, progress = chat.progress or (liveAttached and liveAttached[chat.id] and chat.liveText) or "" })
	end
	return groups
end
