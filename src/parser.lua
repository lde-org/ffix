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

---@class ffix.c.Parser
---@field private ptr number
---@field private tokens ffix.c.Tokenizer.Token[]
---@field private src string?
local Parser = {}
Parser.__index = Parser

---@class ffix.c.Parser.Type
---@field qualifiers string[]
---@field name string?
---@field inline_kind ("struct"|"union"|"enum")?
---@field inline_tag string?
---@field inline_fields ffix.c.Parser.Field[]?
---@field inline_variants ffix.c.Parser.Variant[]?
---@field inline_attrs ffix.c.Attr[]?
---@field pointer number
---@field reference boolean?

---@class ffix.c.Attr
---@field name string
---@field args string?

---@class ffix.c.Parser.Field
---@field type ffix.c.Parser.Type
---@field name string?
---@field array_size string?
---@field attrs ffix.c.Attr[]?

---@class ffix.c.Parser.Variant
---@field name string

---@class ffix.c.Parser.Param
---@field type ffix.c.Parser.Type
---@field name string?

---@class ffix.c.Parser.Node.TypedefAlias
---@field kind "typedef_alias"
---@field type ffix.c.Parser.Type
---@field name string

---@class ffix.c.Parser.Node.TypedefStruct
---@field kind "typedef_struct"
---@field tag string?
---@field fields ffix.c.Parser.Field[]
---@field name string
---@field attrs ffix.c.Attr[]?

---@class ffix.c.Parser.Node.TypedefEnum
---@field kind "typedef_enum"
---@field tag string?
---@field variants ffix.c.Parser.Variant[]
---@field name string

---@class ffix.c.Parser.Node.TypedefFnPtr
---@field kind "typedef_fnptr"
---@field ret ffix.c.Parser.Type
---@field name string
---@field params ffix.c.Parser.Param[]

---@class ffix.c.Parser.Node.FnDecl
---@field kind "fn_decl"
---@field ret ffix.c.Parser.Type
---@field name string
---@field params ffix.c.Parser.Param[]
---@field asm_name string?
---@field attrs ffix.c.Attr[]?

---@class ffix.c.Parser.Node.ExternVar
---@field kind "extern_var"
---@field type ffix.c.Parser.Type
---@field name string
---@field asm_name string?

---@alias ffix.c.Parser.Node
--- | ffix.c.Parser.Node.TypedefAlias
--- | ffix.c.Parser.Node.TypedefStruct
--- | ffix.c.Parser.Node.TypedefEnum
--- | ffix.c.Parser.Node.TypedefFnPtr
--- | ffix.c.Parser.Node.FnDecl
--- | ffix.c.Parser.Node.ExternVar

function Parser.new()
	return setmetatable({}, Parser)
end

---@return ffix.c.Tokenizer.Token?
function Parser:peek()
	return self.tokens[self.ptr]
end

---@return ffix.c.Tokenizer.Token?
function Parser:advance()
	local tok = self.tokens[self.ptr]
	if tok then self.ptr = self.ptr + 1 end
	return tok
end

---@param variant string
---@return ffix.c.Tokenizer.Token?
function Parser:consume(variant)
	local tok = self.tokens[self.ptr]
	if tok and tok.variant == variant then
		self.ptr = self.ptr + 1
		return tok
	end
end

---@param variant string
---@return ffix.c.Tokenizer.Token
function Parser:expect(variant)
	local tok = self:consume(variant)
	if not tok then
		local got = self.tokens[self.ptr]
		local msg = "expected '" .. variant .. "' got '" .. (got and got.variant or "EOF") .. "'"
		if self.src and got and got.span then
			msg = msg .. "\n" .. errorContext(self.src, got.span[1])
		end
		error(msg)
	end
	return tok
end

local type_quals = { const = true, volatile = true, restrict = true, unsigned = true, signed = true, long = true, short = true }
local base_types = { void = true, char = true, int = true, float = true, double = true }

---@return ffix.c.Parser.Type
function Parser:parseType()
	local quals = {}
	local name

	while true do
		local tok = self:peek()
		if not tok then break end

		if type_quals[tok.variant] then
			quals[#quals + 1] = tok.variant
			self:advance()
		elseif base_types[tok.variant] then
			name = tok.variant
			self:advance()
			break
		elseif tok.variant == "struct" or tok.variant == "enum" or tok.variant == "union" then
			local kw = tok.variant
			self:advance()
			local tag_tok = self:consume("ident")
			if self:peek() and self:peek().variant == "{" then
				self:advance()
				local inline_fields, inline_variants, inline_attrs
				if kw == "enum" then
					inline_variants = self:parseVariants()
				else
					inline_fields = self:parseFields()
					inline_attrs = self:parseAttrs()
				end
				local pointer = 0
				while self:consume("*") do
					pointer = pointer + 1
					while true do
						local qtok = self:peek()
						if qtok and (qtok.variant == "const" or qtok.variant == "volatile" or qtok.variant == "restrict") then
							self:advance()
						else break end
					end
				end
				local reference = self:consume("&") ~= nil
				return {
					qualifiers = quals,
					inline_kind = kw,
					inline_tag = tag_tok and tag_tok.ident,
					inline_fields = inline_fields,
					inline_variants = inline_variants,
					inline_attrs = inline_attrs,
					pointer = pointer,
					reference = reference or nil,
				}
			end
			if not tag_tok then error("expected tag name or '{' after " .. kw) end
			name = kw .. " " .. tag_tok.ident
			break
		elseif tok.variant == "ident" then
			-- if we already have qualifiers (e.g. "unsigned long"), peek at the
			-- token after this ident: if it looks like a declaration suffix
			-- then this ident is a name not a type, so stop here without consuming
			local next = self.tokens[self.ptr + 1]
			local next_v = next and next.variant
			if #quals > 0 and (next_v == "(" or next_v == ";" or next_v == "," or next_v == ")" or next_v == "[") then
				break
			end

			name = tok.ident
			self:advance()
			break
		else
			break
		end
	end

	-- trailing const/volatile after name
	while true do
		local tok = self:peek()
		if tok and type_quals[tok.variant] then
			quals[#quals + 1] = tok.variant
			self:advance()
		else
			break
		end
	end

	if not name then
		-- qualifiers only (e.g. "unsigned" as shorthand for "unsigned int")
		if #quals > 0 then
			name = quals[#quals]
			quals[#quals] = nil
		else
			error("expected type")
		end
	end

	local pointer = 0
	while self:consume("*") do
		pointer = pointer + 1
		-- eat pointer-level qualifiers
		while true do
			local tok = self:peek()
			if tok and (tok.variant == "const" or tok.variant == "volatile" or tok.variant == "restrict") then
				self:advance()
			else
				break
			end
		end
	end

	local reference = self:consume("&") ~= nil

	return { qualifiers = quals, name = name, pointer = pointer, reference = reference or nil }
end

---@return string?
function Parser:parseArraySize()
	if not self:consume("[") then return nil end
	local parts = {}
	while not self:consume("]") do
		local t = self:advance()
		if t.variant == "ident" then
			parts[#parts + 1] = t.ident
		elseif t.variant == "number" then
			local n = t.number
			parts[#parts + 1] = n == math.floor(n) and tostring(math.floor(n)) or tostring(n)
		else
			parts[#parts + 1] = t.variant
		end
	end
	return table.concat(parts)
end

---@return ffix.c.Parser.Field[]
function Parser:parseFields()
	local fields = {}
	while not self:consume("}") do
		local ftype = self:parseType()
		local name_tok
		if ftype.inline_kind then
			name_tok = self:consume("ident")
		else
			name_tok = self:expect("ident")
		end
		local array_size = self:parseArraySize()
		local attrs = self:parseAttrs()
		fields[#fields + 1] = { type = ftype, name = name_tok and name_tok.ident, array_size = array_size, attrs = attrs }
		-- comma-separated names sharing the same base type: unsigned int lo, hi;
		while self:consume(",") do
			local extra_ptr = 0
			while self:consume("*") do extra_ptr = extra_ptr + 1 end
			local extra_name = self:expect("ident")
			local extra_type
			if ftype.inline_kind then
				extra_type = { qualifiers = ftype.qualifiers, inline_kind = ftype.inline_kind,
					inline_tag = ftype.inline_tag, inline_fields = ftype.inline_fields,
					inline_variants = ftype.inline_variants, inline_attrs = ftype.inline_attrs,
					pointer = ftype.pointer + extra_ptr, reference = ftype.reference }
			else
				extra_type = { qualifiers = ftype.qualifiers, name = ftype.name,
					pointer = ftype.pointer + extra_ptr, reference = ftype.reference }
			end
			fields[#fields + 1] = { type = extra_type, name = extra_name.ident, array_size = self:parseArraySize() }
		end
		self:expect(";")
	end
	return fields
end

---@return ffix.c.Parser.Variant[]
function Parser:parseVariants()
	local variants = {}
	while not self:consume("}") do
		local name = self:expect("ident")
		local value
		if self:consume("=") then
			local tok = self:advance()
			value = tok.variant == "number" and tok.number or tok.variant
		end
		self:consume(",")
		variants[#variants + 1] = { name = name.ident, value = value }
	end
	return variants
end

---@return ffix.c.Parser.Param[]
function Parser:parseParams()
	self:expect("(")
	local params = {}
	if self:consume(")") then return params end
	-- (void) means no params, but (void *) is a real param — peek ahead
	if self.tokens[self.ptr] and self.tokens[self.ptr].variant == "void"
		and self.tokens[self.ptr + 1] and self.tokens[self.ptr + 1].variant == ")" then
		self.ptr = self.ptr + 2
		return params
	end
	while true do
		if self:consume("...") then
			self:consume(")")
			break
		end
		local ptype = self:parseType()
		local name_tok
		-- function pointer param: ret (*name)(inner_params)
		if self:peek() and self:peek().variant == "("
			and self.tokens[self.ptr + 1] and self.tokens[self.ptr + 1].variant == "*" then
			self:advance() -- (
			self:advance() -- *
			name_tok = self:consume("ident")
			self:expect(")")
			local fnparams = self:parseParams()
			ptype = { fnptr = true, ret = ptype, params = fnparams, pointer = 0 }
		else
			name_tok = self:consume("ident")
			-- array-notation params: char *argv[] → treat as pointer (consume and discard brackets)
			if self:consume("[") then
				while not self:consume("]") do self:advance() end
				ptype = { qualifiers = ptype.qualifiers, name = ptype.name, inline_kind = ptype.inline_kind,
					inline_tag = ptype.inline_tag, inline_fields = ptype.inline_fields,
					inline_variants = ptype.inline_variants, inline_attrs = ptype.inline_attrs,
					pointer = ptype.pointer + 1, reference = ptype.reference }
			end
		end
		params[#params + 1] = { type = ptype, name = name_tok and name_tok.ident }
		if self:consume(")") then break end
		self:expect(",")
	end
	return params
end

---@return string?
function Parser:parseAsmName()
	local tok = self:peek()
	if tok and tok.variant == "ident" and (tok.ident == "__asm__" or tok.ident == "asm") then
		self:advance()
		self:expect("(")
		local str = self:expect("string")
		self:expect(")")
		return str.string
	end
end

---@return ffix.c.Attr[]?
function Parser:parseAttrs()
	local tok = self:peek()
	if not (tok and tok.variant == "ident" and tok.ident == "__attribute__") then return nil end
	self:advance()
	self:expect("(")
	self:expect("(")
	local attrs = {}
	while true do
		if self:consume(")") then break end
		local name_tok = self:advance()
		local name = name_tok.variant == "ident" and name_tok.ident or name_tok.variant
		local args
		if self:consume("(") then
			local parts = {}
			local depth = 0
			while true do
				local t = self:peek()
				if not t then error("unterminated __attribute__ args") end
				if t.variant == ")" then
					if depth == 0 then break end
					depth = depth - 1
					parts[#parts + 1] = ")"
					self:advance()
				elseif t.variant == "(" then
					depth = depth + 1
					parts[#parts + 1] = "("
					self:advance()
				elseif t.variant == "ident" then
					parts[#parts + 1] = t.ident
					self:advance()
				elseif t.variant == "number" then
					local n = t.number
					parts[#parts + 1] = n == math.floor(n) and tostring(math.floor(n)) or tostring(n)
					self:advance()
				else
					parts[#parts + 1] = t.variant
					self:advance()
				end
			end
			args = table.concat(parts)
			self:expect(")")
		end
		attrs[#attrs + 1] = { name = name, args = args }
		self:consume(",")
	end
	self:expect(")")
	return attrs
end

---@return ffix.c.Parser.Node[]
function Parser:parseDecl()
	if self:consume("typedef") then
		local kw = self:peek()

		if kw and (kw.variant == "struct" or kw.variant == "union") then
			local kw_str = kw.variant
			self:advance()
			local pre_attrs = self:parseAttrs()
			local tag_tok = self:consume("ident")

			-- forward typedef: typedef struct Foo Foo; (no body follows)
			if not (self:peek() and self:peek().variant == "{") then
				if not tag_tok then error("expected tag or '{' after " .. kw_str) end
				local name = self:expect("ident")
				self:expect(";")
				return {{ kind = "typedef_alias",
					type = { qualifiers = {}, name = kw_str .. " " .. tag_tok.ident, pointer = 0 },
					name = name.ident }}
			end

			self:expect("{")
			local fields = self:parseFields()
			local post_attrs = self:parseAttrs()
			local attrs
			if pre_attrs or post_attrs then
				attrs = {}
				if pre_attrs then for _, a in ipairs(pre_attrs) do attrs[#attrs + 1] = a end end
				if post_attrs then for _, a in ipairs(post_attrs) do attrs[#attrs + 1] = a end end
			end

			local first_name = self:expect("ident")
			local result = {{ kind = "typedef_struct", kw = kw_str,
				tag = tag_tok and tag_tok.ident, fields = fields,
				name = first_name.ident, attrs = attrs }}
			-- additional declarators: typedef struct { } Foo, *FooPtr;
			while self:consume(",") do
				local ptr = 0
				while self:consume("*") do ptr = ptr + 1 end
				local alias_name = self:expect("ident")
				result[#result + 1] = { kind = "typedef_alias",
					type = { qualifiers = {}, name = first_name.ident, pointer = ptr },
					name = alias_name.ident }
			end
			self:expect(";")
			return result
		end

		if kw and kw.variant == "enum" then
			self:advance()
			local tag_tok = self:consume("ident")
			self:expect("{")
			local variants = self:parseVariants()
			local name = self:expect("ident")
			self:expect(";")
			return {{ kind = "typedef_enum", tag = tag_tok and tag_tok.ident, variants = variants, name = name.ident }}
		end

		local ret = self:parseType()

		-- function pointer: typedef ret (*name)(params);
		if self:consume("(") then
			self:expect("*")
			local name = self:expect("ident")
			self:expect(")")
			local params = self:parseParams()
			self:expect(";")
			return {{ kind = "typedef_fnptr", ret = ret, name = name.ident, params = params }}
		end

		local name = self:expect("ident")
		self:expect(";")
		return {{ kind = "typedef_alias", type = ret, name = name.ident }}
	end

	if self:consume("extern") then
		local type = self:parseType()
		local name = self:expect("ident")
		if self:consume("[") then
			while not self:consume("]") do self:advance() end
		end
		local asm_name = self:parseAsmName()
		self:expect(";")
		return {{ kind = "extern_var", type = type, name = name.ident, asm_name = asm_name }}
	end

	-- bare struct/union/enum definition: struct Foo { ... };
	local kw_tok = self:peek()
	if kw_tok and (kw_tok.variant == "struct" or kw_tok.variant == "union" or kw_tok.variant == "enum") then
		local saved = self.ptr
		self:advance()
		local tag_tok = self:consume("ident")
		if self:peek() and self:peek().variant == "{" then
			self:advance()
			local fields, variants
			if kw_tok.variant == "enum" then
				variants = self:parseVariants()
			else
				fields = self:parseFields()
			end
			self:expect(";")
			return {{ kind = "struct_def", kw = kw_tok.variant,
				tag = tag_tok and tag_tok.ident, fields = fields, variants = variants }}
		end
		self.ptr = saved
	end

	local ret = self:parseType()
	local name = self:expect("ident")
	local params = self:parseParams()
	local asm_name = self:parseAsmName()
	local attrs = self:parseAttrs()
	self:expect(";")
	return {{ kind = "fn_decl", ret = ret, name = name.ident, params = params, asm_name = asm_name, attrs = attrs }}
end

---@param tokens ffix.c.Tokenizer.Token[]
---@param src string?
---@return boolean, ffix.c.Parser.Node[]
function Parser:parse(tokens, src)
	self.ptr = 1
	self.tokens = tokens
	self.src = src

	local nodes = {}
	local ok, err = pcall(function()
		while self.ptr <= #self.tokens do
			for _, node in ipairs(self:parseDecl()) do
				nodes[#nodes + 1] = node
			end
		end
	end)

	if not ok then
		return false, nodes, err
	end

	return true, nodes
end

return Parser
