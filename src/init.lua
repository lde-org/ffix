local ffi = require("ffi")

local ffix = {}

local Tokenizer = require("ffix.tokenizer")
local Parser = require("ffix.parser")
local Printer = require("ffix.printer")

---@class ffix.Context
---@field private pfx string
---@field private names table<string, string>  -- original -> prefixed
---@field C table  -- proxy for ffi.C; ctx.C.foo resolves to ffi.C[prefixed_name]
local Context = {}
Context.__index = Context

---@param t ffix.c.Parser.Type
---@return ffix.c.Parser.Type
function Context:rewriteInlineType(t)
	local result = {
		qualifiers = t.qualifiers,
		inline_kind = t.inline_kind,
		inline_tag = t.inline_tag,
		inline_attrs = t.inline_attrs,
		pointer = t.pointer,
		reference = t.reference
	}
	if t.inline_kind == "enum" then
		result.inline_variants = self:rewriteVariants(t.inline_variants)
	else
		local fields = {}
		for _, f in ipairs(t.inline_fields) do
			fields[#fields + 1] = {
				type = self:rewriteType(f.type),
				name = f.name,
				array_size = f.array_size,
				attrs = f
					.attrs
			}
		end
		result.inline_fields = fields
	end
	return result
end

---@param t ffix.c.Parser.Type
---@return ffix.c.Parser.Type
function Context:rewriteType(t)
	if t.fnptr then
		return { fnptr = true, ret = self:rewriteType(t.ret), params = self:rewriteParams(t.params), pointer = t.pointer }
	end
	if t.inline_kind then
		return self:rewriteInlineType(t)
	end

	local name = t.name

	local kw, base = name:match("^(%a+) ([%a_][%w_]*)$")
	if kw == "struct" or kw == "enum" or kw == "union" then
		name = kw .. " " .. (self.names[base] or base)
	else
		name = self.names[name] or name
	end

	return { qualifiers = t.qualifiers, name = name, pointer = t.pointer, reference = t.reference }
end

---@param variants table
---@return table
function Context:rewriteVariants(variants)
	local out = {}
	for _, v in ipairs(variants) do
		out[#out + 1] = { name = self.pfx .. "_" .. v.name, value = v.value }
	end
	return out
end

---@param params ffix.c.Parser.Param[]
---@return ffix.c.Parser.Param[]
function Context:rewriteParams(params)
	local out = {}
	for _, p in ipairs(params) do
		if p.vararg then
			out[#out + 1] = p
		else
			out[#out + 1] = { type = self:rewriteType(p.type), name = p.name }
		end
	end

	return out
end

---@format disable-next
---@private
---@param node ffix.c.Parser.Node
---@return ffix.c.Parser.Node
function Context:rewriteNode(node)
	local k = node.kind
	local renamed = self.names[node.name] or node.name

	if k == "typedef_alias" then
		return { kind = k, name = renamed, type = self:rewriteType(node.type) }
	elseif k == "typedef_struct" then
		local fields = {}
		for _, f in ipairs(node.fields) do
			fields[#fields + 1] = { type = self:rewriteType(f.type), name = f.name, array_size = f.array_size, attrs = f.attrs }
		end

		return { kind = k, name = renamed, tag = node.tag and (self.names[node.tag] or node.tag), fields = fields, attrs = node.attrs }
	elseif k == "typedef_enum" then
		return { kind = k, name = renamed, tag = node.tag and (self.names[node.tag] or node.tag), variants = self:rewriteVariants(node.variants) }
	elseif k == "typedef_fnptr" then
		return { kind = k, name = renamed, ret = self:rewriteType(node.ret), params = self:rewriteParams(node.params) }
	elseif k == "fn_decl" then
		return { kind = k, name = renamed, asm_name = node.asm_name or node.name, ret = self:rewriteType(node.ret), params = self:rewriteParams(node.params), attrs = node.attrs }
	elseif k == "extern_var" then
		return { kind = k, name = renamed, asm_name = node.name, type = self:rewriteType(node.type) }
	elseif k == "struct_def" then
		local fields
		if node.fields then
			fields = {}
			for _, f in ipairs(node.fields) do
				fields[#fields + 1] = { type = self:rewriteType(f.type), name = f.name, array_size = f.array_size, attrs = f.attrs }
			end
		end

		local renamed_tag = node.tag and (self.names[node.tag] or node.tag)
		return { kind = k, kw = node.kw, tag = renamed_tag, fields = fields, variants = node.variants and self:rewriteVariants(node.variants) }
	end

	error("unknown node kind: " .. tostring(node.kind))
end

---@param code string
function Context:cdef(code)
	local tokens = Tokenizer.new():tokenize(code)
	local ok, nodes, err = Parser.new():parse(tokens, code)
	if not ok then error("ffix: " .. tostring(err)) end

	-- first pass: register all declared names and tags
	for _, node in ipairs(nodes) do
		if node.name then
			self.names[node.name] = self.pfx .. "_" .. node.name
		end
		if node.tag and not self.names[node.tag] then
			self.names[node.tag] = self.pfx .. "_" .. node.tag
		end
	end

	-- second pass: rewrite and emit
	local rewritten = {}
	for _, node in ipairs(nodes) do
		rewritten[#rewritten + 1] = self:rewriteNode(node)
	end

	ffi.cdef(Printer.new():print(rewritten))
end

---@format disable-next
local builtinTypes = {
	["void"] = true,
	["bool"] = true,
	["char"] = true,
	["short"] = true,
	["int"] = true,
	["long"] = true,
	["float"] = true,
	["double"] = true,
	["unsigned"] = true,
	["signed"] = true,
	["int8_t"] = true, ["int16_t"] = true, ["int32_t"] = true, ["int64_t"] = true,
	["uint8_t"] = true, ["uint16_t"] = true, ["uint32_t"] = true, ["uint64_t"] = true,
	["size_t"] = true, ["ptrdiff_t"] = true, ["intptr_t"] = true, ["uintptr_t"] = true,
}

-- Resolves a typename string, handling const, struct/enum/union tags, built-ins,
-- and trailing pointer/array decorators. Errors if the base name is unknown.
---@param typename string
---@return string
function Context:resolveTypename(typename)
	local s = typename

	local prefix = ""
	local const, rest = s:match("^(const%s+)(.*)")
	if const then
		prefix = const
		s = rest
	end

	local kw, tag, tail = s:match("^(struct%s+)([%a_][%w_]*)(.*)")
	if not kw then
		kw, tag, tail = s:match("^(enum%s+)([%a_][%w_]*)(.*)")
	end
	if not kw then
		kw, tag, tail = s:match("^(union%s+)([%a_][%w_]*)(.*)")
	end

	if kw then
		local resolved = self.names[tag]
		if not resolved then error("unknown typename: " .. kw .. tag) end
		return prefix .. kw .. resolved .. tail
	end

	local base, tail2 = s:match("^([%a_][%w_]*)(.*)")
	if base then
		if builtinTypes[base] then
			return prefix .. s
		end
		local resolved = self.names[base]
		if not resolved then error("unknown typename: " .. base) end
		return prefix .. resolved .. tail2
	end

	error("invalid typename: " .. typename)
end

---@param typename string|ffi.ctype*
function Context:new(typename, ...)
	if type(typename) ~= "string" then return ffi.new(typename, ...) end
	return ffi.new(self:resolveTypename(typename), ...)
end

---@param typename string|ffi.ctype*
function Context:cast(typename, ...)
	if type(typename) ~= "string" then return ffi.cast(typename, ...) end
	if typename:find("%(") then
		local resolved = typename:gsub("%f[%a_][%a_][%w_]*", function(ident)
			return self.names[ident] or ident
		end)
		return ffi.cast(resolved, ...)
	end
	return ffi.cast(self:resolveTypename(typename), ...)
end

---@param typename string|ffi.ctype*
function Context:typeof(typename)
	if type(typename) ~= "string" then return ffi.typeof(typename) end
	return ffi.typeof(self:resolveTypename(typename))
end

---@param typename string|ffi.ctype*
function Context:sizeof(typename)
	if type(typename) ~= "string" then return ffi.sizeof(typename) end
	return ffi.sizeof(self:resolveTypename(typename))
end

--- TODO: field should be prefixed too...
---@param typename string|ffi.ctype*
---@param field string
function Context:offsetof(typename, field)
	if type(typename) ~= "string" then return ffi.offsetof(typename, field) end
	return ffi.offsetof(self:resolveTypename(typename), field)
end

---@param typename string|ffi.ctype*
function Context:alignof(typename)
	if type(typename) ~= "string" then return ffi.alignof(typename) end
	return ffi.alignof(self:resolveTypename(typename))
end

---@param lib string
function Context:load(lib)
	local loaded = ffi.load(lib)
	return setmetatable({}, {
		__index = function(t, k)
			local v = loaded[self.names[k] or k]
			rawset(t, k, v)
			return v
		end
	})
end

---@param typename string|ffi.ctype*
---@param mt table
function Context:metatype(typename, mt)
	if type(typename) ~= "string" then return ffi.metatype(typename, mt) end
	return ffi.metatype(self:resolveTypename(typename), mt)
end

---@param typename string|ffi.ctype*
function Context:istype(typename, obj)
	if type(typename) ~= "string" then return ffi.istype(typename, obj) end
	return ffi.istype(self:resolveTypename(typename), obj)
end

---@param ctx table
local function generatePrefix(ctx)
	return string.format("ffix_%d%p", os.clock() * 1e6, ctx)
end

---@param pfx string?
function ffix.context(pfx)
	local ctx = setmetatable({ names = {} }, Context)
	ctx.pfx = pfx or generatePrefix(ctx)

	ctx.C = setmetatable({}, {
		__index = function(t, k)
			local v = ffi.C[ctx.names[k] or k]
			rawset(t, k, v)
			return v
		end
	})

	return ctx
end

return ffix
