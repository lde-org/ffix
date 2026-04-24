local function errorContext(src, pos)
	local lines, starts = {}, {1}
	for i = 1, #src do
		if src:sub(i, i) == "\n" then
			lines[#lines + 1] = src:sub(starts[#starts], i - 1)
			starts[#starts + 1] = i + 1
		end
	end
	lines[#lines + 1] = src:sub(starts[#starts])

	local err_line = #starts
	for i = 1, #starts - 1 do
		if starts[i + 1] > pos then err_line = i; break end
	end
	local col = pos - starts[err_line] + 1

	local out = {}
	for l = math.max(1, err_line - 1), math.min(#lines, err_line + 1) do
		out[#out + 1] = string.format("%4d | %s", l, lines[l])
		if l == err_line then
			out[#out + 1] = "     | " .. lines[l]:sub(1, col - 1):gsub("[^\t]", " ") .. "^"
		end
	end
	return string.format("line %d col %d\n%s", err_line, col, table.concat(out, "\n"))
end

---@class ffix.c.Tokenizer
---@field private ptr number
---@field private len number
---@field private src string
local Tokenizer = {}
Tokenizer.__index = Tokenizer

function Tokenizer.new()
	return setmetatable({}, Tokenizer)
end

---@param pattern string
function Tokenizer:skip(pattern)
	local start, finish = string.find(self.src, pattern, self.ptr)
	if start then
		self.ptr = finish + 1
		return true
	end
end

---@param pattern string
---@return string?
function Tokenizer:consume(pattern)
	local start, finish, match = string.find(self.src, pattern, self.ptr)
	if start then
		self.ptr = finish + 1
		return match or true
	end
end

function Tokenizer:skipWhitespace()
	return self:skip("^%s+")
end

function Tokenizer:skipLineComment()
	return self:skip("^//[^\n]*\n?") or self:skip("^#[^\n]*\n?")
end

function Tokenizer:skipBlockComment()
	if string.sub(self.src, self.ptr, self.ptr + 1) ~= "/*" then return end
	local finish = string.find(self.src, "*/", self.ptr + 2, true)
	self.ptr = finish and (finish + 2) or (self.len + 1)
	return true
end

function Tokenizer:skipComments()
	return self:skipLineComment() or self:skipBlockComment()
end

---@class ffix.c.Tokenizer.Token.Ident
---@field variant "ident"
---@field ident string

---@class ffix.c.Tokenizer.Token.Number
---@field variant "number"
---@field number number

---@class ffix.c.Tokenizer.Token.String
---@field variant "string"
---@field number string

---@class ffix.c.Tokenizer.Token.Special
---@field variant string

---@alias ffix.c.Tokenizer.Token
--- | ffix.c.Tokenizer.Token.Ident
--- | ffix.c.Tokenizer.Token.String
--- | ffix.c.Tokenizer.Token.Number
--- | ffix.c.Tokenizer.Token.Special

---@type table<string, true>
local special = {}

for _, s in ipairs({
	"typedef", "{", "}", "[", "]", "(", ")", ",", ".", ";", ":", "<", ">", "*", "&", "~", "...", "::",
	"struct", "enum", "union", "const", "restrict", "extern", "static", "volatile",
	"unsigned", "signed", "void", "char", "short", "int", "long", "float", "double"
}) do
	special[s] = true
end

---@return ffix.c.Tokenizer.Token?
function Tokenizer:next()
	local ident = self:consume("^([%a_][%w_]*)")
	if ident then
		if special[ident] then
			return { variant = ident }
		end

		return { variant = "ident", ident = ident }
	end

	local dec = self:consume("^(%d+%.%d+)")
	if dec then
		return { variant = "number", number = tonumber(dec) }
	end

	local hex = self:consume("^0x([%x]+)")
	if hex then
		return { variant = "number", number = tonumber(hex, 16) }
	end

	local int = self:consume("^(%d+)[uUlL]*")
	if int then
		return { variant = "number", number = tonumber(int) }
	end

	local str = self:consume("^\"([^\"]+)\"")
	if str then
		return { variant = "string", string = str }
	end

	local three = string.sub(self.src, self.ptr, self.ptr + 2)
	if special[three] then
		self.ptr = self.ptr + 3
		return { variant = three }
	end

	local two = string.sub(self.src, self.ptr, self.ptr + 1)
	if special[two] then
		self.ptr = self.ptr + 2
		return { variant = two }
	end

	local one = string.sub(self.src, self.ptr, self.ptr)
	if special[one] then
		self.ptr = self.ptr + 1
		return { variant = one }
	end
end

---@param src string
function Tokenizer:tokenize(src)
	self.ptr = 1
	self.len = #src
	self.src = src

	---@type ffix.c.Tokenizer.Token[]
	local tokens = {}

	while true do
		while self:skipWhitespace() or self:skipComments() do end
		if self.ptr > self.len then break end

		local start = self.ptr
		local tok = self:next()
		if not tok then
			local ch = string.sub(self.src, self.ptr, self.ptr)
			error("ffix: unexpected character '" .. ch .. "'\n" .. errorContext(self.src, self.ptr))
		end

		tok.span = {start, self.ptr - 1}
		tokens[#tokens + 1] = tok
	end

	return tokens
end

return Tokenizer
