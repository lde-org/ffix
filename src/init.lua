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
		out[#out + 1] = { type = self:rewriteType(p.type), name = p.name }
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

---@param typename string
function Context:new(typename, ...)
	return ffi.new(self.names[typename] or typename, ...)
end

---@param typename string
function Context:cast(typename, ...)
	local base, tail = typename:match("^([%a_][%w_]*)(.*)")
	if base and self.names[base] then typename = self.names[base] .. tail end
	return ffi.cast(typename, ...)
end

---@param typename string
function Context:typeof(typename)
	return ffi.typeof(self.names[typename] or typename)
end

---@param typename string
function Context:sizeof(typename)
	return ffi.sizeof(self.names[typename] or typename)
end

---@param typename string
---@param field string
function Context:offsetof(typename, field)
	return ffi.offsetof(self.names[typename] or typename, field)
end

---@param typename string
function Context:alignof(typename)
	return ffi.alignof(self.names[typename] or typename)
end

---@param lib string
function Context:load(lib)
	return ffi.load(lib)
end

---@param typename string
---@param mt table
function Context:metatype(typename, mt)
	return ffi.metatype(self.names[typename] or typename, mt)
end

---@param typename string
function Context:istype(typename, obj)
	return ffi.istype(self.names[typename] or typename, obj)
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
		__index = function(_, k)
			return ffi.C[ctx.names[k] or k]
		end
	})

	return ctx
end

return ffix
