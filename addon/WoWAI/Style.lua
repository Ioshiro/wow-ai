-- Quest tracker and parchment palette, adapted from Ompcraft (MIT, TechDufus).
WoWAI_Style = {
	BACKDROP = {
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	},
	ROLE_STYLE = {
		user = { label = "You", color = { 0.25, 0.20, 0.13 }, bg = { 0.35, 0.25, 0.1, 0.08 } },
		assistant = { label = "AI", color = { 0.35, 0.10, 0.02 }, bg = { 0.35, 0.25, 0.1, 0.05 } },
		system = { label = "System", color = { 0.42, 0.34, 0.24 }, bg = { 0.35, 0.25, 0.1, 0.05 } },
	},
}
