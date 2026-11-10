-- Markdown rendering adapted from ompcraft by TechDufus (MIT license).
-- This module is pure Lua 5.1 and does not depend on the WoW API.
local Markdown = {}

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function escape(text)
	return (text:gsub("|", "||"))
end

local function inline(text, color)
	local out = {}
	local i = 1
	local function add(value)
		out[#out + 1] = value
	end
	while i <= #text do
		local char = text:sub(i, i)
		if char == "`" then
			local run = text:match("^`+", i)
			local cursor = i + #run
			local close
			while cursor <= #text do
				local start = text:find("`", cursor, true)
				if not start then break end
				local ticks = text:match("^`+", start)
				if #ticks == #run then close = start; break end
				cursor = start + #ticks
			end
			if close then
				local body = text:sub(i + #run, close - 1)
				if #body > 1 and body:sub(1, 1) == " " and body:sub(-1) == " " and trim(body) ~= "" then
					body = body:sub(2, -2)
				end
				add("|cff694018" .. escape(body) .. "|r" .. (color or ""))
				i = close + #run
			else
				add(run)
				i = i + #run
			end
		elseif text:sub(i, i + 1) == "**" then
			local close = text:find("**", i + 2, true)
			if close and close > i + 2 then
				local bold = "|cff39200d"
				add(bold .. inline(text:sub(i + 2, close - 1), bold) .. "|r" .. (color or ""))
				i = close + 2
			else
				add("**")
				i = i + 2
			end
		elseif char == "[" or (char == "!" and text:sub(i + 1, i + 1) == "[") then
			local start = char == "!" and i + 1 or i
			local bracket = text:find("]", start + 1, true)
			local endpos
			if bracket and text:sub(bracket + 1, bracket + 1) == "(" then
				local depth = 1
				local cursor = bracket + 2
				while cursor <= #text and depth > 0 do
					local c = text:sub(cursor, cursor)
					if c == "(" then depth = depth + 1 elseif c == ")" then depth = depth - 1 end
					cursor = cursor + 1
				end
				if depth == 0 then endpos = cursor - 1 end
			elseif bracket and text:sub(bracket + 1, bracket + 1) == "[" then
				endpos = text:find("]", bracket + 2, true)
			end
			if endpos then
				add(inline(text:sub(start + 1, bracket - 1), color))
				i = endpos + 1
			else
				add(escape(char))
				i = i + 1
			end
		elseif char == "\\" and i < #text and text:sub(i + 1, i + 1):match("[%p]") then
			add(escape(text:sub(i + 1, i + 1)))
			i = i + 2
		else
			add(escape(char))
			i = i + 1
		end
	end
	return table.concat(out)
end

local function indent(text)
	local prefix = text:match("^[ \t]*")
	local _, tabs = prefix:gsub("\t", "")
	return #prefix + tabs * 3
end

local function fence(line)
	local leading, rest = line:match("^([ \t]*)(.*)$")
	local marker = rest:match("^`+") or rest:match("^~+")
	if not marker or #marker < 3 then return nil end
	return marker, rest:sub(#marker + 1), #leading
end

local function tableCells(line)
	line = trim(line)
	if line:sub(1, 1) == "|" then line = line:sub(2) end
	local cells, part = {}, {}
	local i, code = 1, nil
	while i <= #line do
		local char = line:sub(i, i)
		if char == "\\" and line:sub(i + 1, i + 1) == "|" then
			part[#part + 1] = "\\|"
			i = i + 2
		elseif char == "`" then
			local ticks = line:match("^`+", i)
			if not code then code = #ticks elseif code == #ticks then code = nil end
			part[#part + 1] = ticks
			i = i + #ticks
		elseif char == "|" and not code then
			cells[#cells + 1] = trim(table.concat(part))
			part = {}
			i = i + 1
		else
			part[#part + 1] = char
			i = i + 1
		end
	end
	local last = trim(table.concat(part))
	if last ~= "" or line:sub(-1) ~= "|" then cells[#cells + 1] = last end
	return cells
end

function Markdown.Render(text)
	local rows, lines = {}, {}
	text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
	local pending, parts, pendingDepth
	local gap, stack = false, {}
	local marker, fenceIndent
	local function emit(kind, value, depth)
		if gap and #rows > 0 and rows[#rows].kind ~= "gap" then
			rows[#rows + 1] = { kind = "gap", text = "" }
		end
		gap = false
		local row = { kind = kind, text = value }
		if depth then row.depth = depth end
		rows[#rows + 1] = row
		if kind ~= "li" then stack = {} end
	end
	local function flush()
		if pending then
			local value = trim(table.concat(parts, " "))
			if value ~= "" then emit(pending, inline(value), pendingDepth) end
			pending, parts, pendingDepth = nil, nil, nil
		end
	end
	for _, line in ipairs(lines) do
		local fenceMarker, fenceRest, leading = fence(line)
		if marker then
			if fenceMarker and fenceMarker:sub(1, 1) == marker:sub(1, 1) and #fenceMarker >= #marker and trim(fenceRest) == "" then
				marker = nil
			else
				local remove = 0
				while remove < fenceIndent and line:sub(remove + 1, remove + 1) == " " do remove = remove + 1 end
				emit("code", escape(line:sub(remove + 1)))
			end
		elseif fenceMarker and (fenceMarker:sub(1, 1) ~= "`" or not fenceRest:find("`", 1, true)) then
			flush()
			marker, fenceIndent = fenceMarker, leading
		else
			local stripped = trim(line)
			local spaces, hashes, heading = line:match("^( *)(#+)[ \t]*(.-)[ \t]*$")
			if hashes and (#spaces > 3 or #hashes > 6 or (heading ~= "" and not line:match("^ *#+[ \t]"))) then hashes = nil end
			local rule = stripped:gsub("[ \t]", "")
			local isRule = #rule >= 3 and (rule:match("^%-+$") or rule:match("^%*+$") or rule:match("^_+$")) and indent(line) <= 3
			local quote = line:match("^ *[>](.*)$")
			if indent(line) > 3 then quote = nil end
			local listIndent, bullet, body = line:match("^([ \t]*)([-*+])[ \t]+(.*)$")
			if not bullet then listIndent, bullet, body = line:match("^([ \t]*)(%d+[.)])[ \t]+(.*)$") end
			if stripped == "" then
				flush(); gap = true
			elseif hashes then
				flush()
				heading = trim((heading:gsub("[ \t]+#+[ \t]*$", "")))
				if heading ~= "" then emit("h", inline(heading)) end
			elseif isRule then
				flush(); emit("hr", "")
			elseif quote then
				flush()
				quote = trim(quote)
				while quote:sub(1, 1) == ">" do quote = trim(quote:sub(2)) end
				if quote == "" then gap = true else emit("quote", inline(quote)) end
			elseif bullet and trim(body) ~= "" then
				flush()
				local level = indent(listIndent)
				while #stack > 0 and level < stack[#stack] do stack[#stack] = nil end
				if #stack == 0 or level >= stack[#stack] + 2 then stack[#stack + 1] = level end
				pending, parts, pendingDepth = "li", { trim(body) }, #stack
			elseif stripped:sub(1, 1) == "|" then
				flush()
				if not stripped:match("^[|:%-%s]+$") then
					local cells, rendered, any = tableCells(stripped), {}, false
					for _, cell in ipairs(cells) do
						if cell ~= "" then any = true end
						rendered[#rendered + 1] = inline(cell)
					end
					if any then emit("tr", table.concat(rendered, "  ·  ")) end
				end
			elseif pending == "li" and indent(line) >= 2 then
				parts[#parts + 1] = stripped
			elseif pending == "p" then
				parts[#parts + 1] = stripped
			else
				flush(); pending, parts = "p", { stripped }
			end
		end
	end
	flush()
	return rows
end

WoWAI_Markdown = Markdown
