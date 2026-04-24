local test = require("lde-test")
local ffi = require("ffi")
local ffix = require("ffix")

-- each test gets a unique prefix so cdef doesn't see duplicate type names across runs
local n = 0
local function ctx()
	n = n + 1
	return ffix.context("t" .. n)
end

-- sizeof

test.it("sizeof resolves prefixed struct", function()
	local c = ctx()
	c:cdef("typedef struct { int x; int y; } Point;")
	test.equal(c:sizeof("Point"), ffi.sizeof("int") * 2)
end)

test.it("sizeof resolves prefixed alias", function()
	local c = ctx()
	c:cdef("typedef int MyInt;")
	test.equal(c:sizeof("MyInt"), ffi.sizeof("int"))
end)

-- typeof

test.it("typeof returns the right ctype", function()
	local c = ctx()
	c:cdef("typedef struct { float x; float y; float z; } Vec3;")
	local ct = c:typeof("Vec3")
	test.equal(ffi.sizeof(ct), ffi.sizeof("float") * 3)
end)

-- new

test.it("new creates a zero-initialised struct", function()
	local c = ctx()
	c:cdef("typedef struct { int a; int b; } Pair;")
	local p = c:new("Pair")
	test.equal(p.a, 0)
	test.equal(p.b, 0)
end)

test.it("new with initialiser sets fields", function()
	local c = ctx()
	c:cdef("typedef struct { int x; int y; } Coord;")
	local p = c:new("Coord", { x = 3, y = 7 })
	test.equal(p.x, 3)
	test.equal(p.y, 7)
end)

test.it("new field writes survive a read back", function()
	local c = ctx()
	c:cdef("typedef struct { int val; } Box;")
	local b = c:new("Box")
	b.val = 99
	test.equal(b.val, 99)
end)

-- cast

test.it("cast with bare type name works", function()
	local c = ctx()
	c:cdef("typedef struct { int n; } Wrap;")
	local w = c:new("Wrap", { n = 42 })
	local p = c:cast("Wrap *", w)
	test.equal(p.n, 42)
end)

test.it("cast pointer write is visible through original", function()
	local c = ctx()
	c:cdef("typedef struct { int n; } Cell;")
	local cell = c:new("Cell", { n = 1 })
	local ptr = c:cast("Cell *", cell)
	ptr.n = 55
	test.equal(cell.n, 55)
end)

-- function resolution via __asm__

test.it("declared function resolves to the real symbol via asm", function()
	local c = ctx()
	c:cdef("unsigned long strlen(const char * s);")
	-- rewriter emits: unsigned long tN_strlen(const char *s) __asm__("strlen");
	local pfx_strlen = ffi.C[c.names["strlen"]]
	test.equal(tonumber(pfx_strlen("hello")), 5)
	test.equal(tonumber(pfx_strlen("")), 0)
end)

test.it("multiple functions resolve independently", function()
	local c = ctx()
	c:cdef([[
		unsigned long strlen(const char * s);
		int atoi(const char * s);
	]])
	test.equal(tonumber(ffi.C[c.names["strlen"]]("abc")), 3)
	test.equal(tonumber(ffi.C[c.names["atoi"]]("123")), 123)
end)

-- ctx.C

test.it("ctx.C.fn calls through to the real symbol", function()
	local c = ctx()
	c:cdef("unsigned long strlen(const char * s);")
	test.equal(tonumber(c.C.strlen("hello")), 5)
	test.equal(tonumber(c.C.strlen("")), 0)
end)

test.it("ctx.C resolves multiple functions independently", function()
	local c = ctx()
	c:cdef([[
		unsigned long strlen(const char * s);
		int atoi(const char * s);
	]])
	test.equal(tonumber(c.C.strlen("abc")), 3)
	test.equal(tonumber(c.C.atoi("42")), 42)
end)

test.it("ctx.C from different contexts do not collide", function()
	local c1 = ctx()
	local c2 = ctx()
	c1:cdef("unsigned long strlen(const char * s);")
	c2:cdef("unsigned long strlen(const char * s);")
	test.equal(tonumber(c1.C.strlen("hi")), 2)
	test.equal(tonumber(c2.C.strlen("hello")), 5)
end)

-- metatype

test.it("metatype registers methods accessible on new instances", function()
	local c = ctx()
	c:cdef("typedef struct { int x; int y; } Point;")
	c:metatype("Point", {
		__index = {
			sum = function(self) return self.x + self.y end,
		},
	})
	local p = c:new("Point", { x = 3, y = 4 })
	test.equal(p:sum(), 7)
end)

test.it("metatype __tostring is called on tostring()", function()
	local c = ctx()
	c:cdef("typedef struct { int n; } Num;")
	c:metatype("Num", {
		__tostring = function(self) return "Num(" .. self.n .. ")" end,
	})
	local v = c:new("Num", { n = 99 })
	test.equal(tostring(v), "Num(99)")
end)

-- istype

test.it("istype returns true for matching ctype", function()
	local c = ctx()
	c:cdef("typedef struct { int x; } Vec;")
	local v = c:new("Vec")
	test.truthy(c:istype("Vec", v))
end)

test.it("istype returns false for non-matching ctype", function()
	local c = ctx()
	c:cdef("typedef struct { int x; } A;")
	c:cdef("typedef struct { int x; } B;")
	local a = c:new("A")
	test.falsy(c:istype("B", a))
end)

-- error formatting

test.it("parse error includes line, col and source context", function()
	local c = ctx()
	local ok, err = pcall(function()
		c:cdef([[
			typedef struct {
				int x
			} Foo;
		]])
	end)
	test.falsy(ok)
	test.truthy(err:find("line 3"))
	test.truthy(err:find("col"))
	test.truthy(err:find("int x"))
	test.truthy(err:find("%^"))
end)

-- ffix.context() with no prefix (auto-generated)

test.it("no-prefix context gets a non-empty pfx", function()
	local c = ffix.context()
	test.truthy(type(c.pfx) == "string" and #c.pfx > 0)
end)

test.it("no-prefix context: sizeof resolves struct", function()
	local c = ffix.context()
	c:cdef("typedef struct { int x; int y; } AutoPoint;")
	test.equal(c:sizeof("AutoPoint"), ffi.sizeof("int") * 2)
end)

test.it("no-prefix context: new creates zero-initialised struct", function()
	local c = ffix.context()
	c:cdef("typedef struct { int a; int b; } AutoPair;")
	local p = c:new("AutoPair")
	test.equal(p.a, 0)
	test.equal(p.b, 0)
end)

test.it("no-prefix context: new with initialiser sets fields", function()
	local c = ffix.context()
	c:cdef("typedef struct { int x; int y; } AutoCoord;")
	local p = c:new("AutoCoord", { x = 5, y = 9 })
	test.equal(p.x, 5)
	test.equal(p.y, 9)
end)

test.it("no-prefix context: typeof returns usable ctype", function()
	local c = ffix.context()
	c:cdef("typedef struct { float x; float y; } AutoVec2;")
	local ct = c:typeof("AutoVec2")
	test.equal(ffi.sizeof(ct), ffi.sizeof("float") * 2)
end)

test.it("no-prefix context: cast pointer write is visible through original", function()
	local c = ffix.context()
	c:cdef("typedef struct { int n; } AutoCell;")
	local cell = c:new("AutoCell", { n = 7 })
	local ptr = c:cast("AutoCell *", cell)
	ptr.n = 88
	test.equal(cell.n, 88)
end)

test.it("no-prefix context: C proxy resolves functions", function()
	local c = ffix.context()
	c:cdef("unsigned long strlen(const char * s);")
	test.equal(tonumber(c.C.strlen("world")), 5)
end)

test.it("two no-prefix contexts do not collide", function()
	local c1 = ffix.context()
	local c2 = ffix.context()
	c1:cdef("typedef struct { int v; } NpShared;")
	c2:cdef("typedef struct { int v; int w; } NpShared;")
	-- sizes differ, so the two contexts must have resolved to distinct prefixed names
	test.truthy(c1:sizeof("NpShared") ~= c2:sizeof("NpShared"))
end)

test.it("no-prefix context: metatype registers methods", function()
	local c = ffix.context()
	c:cdef("typedef struct { int x; int y; } AutoPt;")
	c:metatype("AutoPt", {
		__index = {
			sum = function(self) return self.x + self.y end,
		},
	})
	local p = c:new("AutoPt", { x = 10, y = 20 })
	test.equal(p:sum(), 30)
end)

test.it("no-prefix context: istype returns true for matching ctype", function()
	local c = ffix.context()
	c:cdef("typedef struct { int x; } AutoVec;")
	local v = c:new("AutoVec")
	test.truthy(c:istype("AutoVec", v))
end)

-- real-world cdef patterns

test.it("mixed unnamed and named params", function()
	local c = ctx()
	c:cdef("void whatever(char* name, char*, int f);")
end)

test.it("win32-style multi-typedef with function", function()
	local c = ctx()
	c:cdef([[
		typedef void* HANDLE;
		typedef unsigned long DWORD;
		typedef struct {
			DWORD nLength;
			void* lpSecurityDescriptor;
			int bInheritHandle;
		} SECURITY_ATTRIBUTES;
		int CreateProcessA(const char*, char*, void*, void*, int, DWORD, void*, const char*, void*, void*);
	]])
end)

test.it("simple void pointer function", function()
	local c = ctx()
	c:cdef("void *dlopen(const char *filename, int flags);")
end)

test.it("variadic function with named params", function()
	local c = ctx()
	c:cdef("int open(const char* path, int flags, ...);")
end)

test.it("bare struct definition followed by function using it", function()
	local c = ctx()
	c:cdef([[
		struct pollfd { int fd; short events; short revents; };
		int poll(struct pollfd* fds, unsigned long nfds, int timeout);
	]])
end)

test.it("forward typedef then bare struct definition", function()
	local c = ctx()
	c:cdef([[
		typedef struct Foo Foo;
		struct Foo { int x; };
	]])
end)

test.it("typedef struct with multiple declarators", function()
	local c = ctx()
	c:cdef("typedef struct Foo { int x; } Foo, *FooPtr;")
end)

test.it("typedef union with anonymous struct member", function()
	local c = ctx()
	c:cdef([[
		typedef union {
			struct { unsigned int lo, hi; };
			unsigned long long val;
		} LARGE_INTEGER;
		int QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount);
	]])
end)

test.it("function with array-notation parameter", function()
	local c = ctx()
	c:cdef("int execv(const char* path, char* const argv[]);")
end)

test.it("extern array declaration", function()
	local c = ctx()
	c:cdef("extern char* environ[];")
end)

test.it("nested anonymous struct field with built-in type", function()
	local c = ctx()
	c:cdef([[
		typedef struct {
			char *name;
			char *email;
			struct {
				int64_t time;
				int offset;
				char sign;
			} when;
		} git_signature;
	]])
	test.truthy(c:sizeof("git_signature") > 0)
end)

test.it("multiple forward typedefs in sequence", function()
	local c = ctx()
	c:cdef([[
		typedef struct git_index     git_index;
		typedef struct git_remote    git_remote;
		typedef struct git_submodule git_submodule;
	]])
end)

test.it("typedef struct with array field and pointer field", function()
	local c = ctx()
	c:cdef([[
		typedef struct { unsigned char id[20]; } git_oid;
		typedef struct { const char *message; int klass; } git_error;
	]])
	test.equal(c:sizeof("git_oid"), 20)
end)

test.it("typedef struct with padding array fields", function()
	local c = ctx()
	c:cdef([[
		typedef struct { char _[376]; const char *checkout_branch; char _rest[32]; } git_clone_options;
		typedef struct { char _[376]; } git_submodule_update_options;
		typedef struct { unsigned int version; unsigned int checkout_strategy; char _rest[136]; } git_checkout_options;
	]])
	test.truthy(c:sizeof("git_clone_options") > 0)
	test.equal(c:sizeof("git_submodule_update_options"), 376)
end)

test.it("bare forward struct declaration", function()
	local c = ctx()
	c:cdef([[
		struct libdeflate_compressor;
		struct libdeflate_decompressor;
	]])
end)

test.it("enum with explicit integer values", function()
	local c = ctx()
	c:cdef([[
		typedef enum {
			RESULT_SUCCESS = 0,
			RESULT_BAD_DATA = 1,
			RESULT_NOMEM = 2
		} result_t;
	]])
	local v = c:new("result_t")
	test.equal(tonumber(v), 0)
end)

test.it("enum variants from two contexts do not collide", function()
	local c1 = ctx()
	local c2 = ctx()
	c1:cdef("typedef enum { MY_OK = 0, MY_ERR = 1 } status_t;")
	c2:cdef("typedef enum { MY_OK = 0, MY_ERR = 1 } status_t;")
end)

test.it("function pointer parameter", function()
	local c = ctx()
	c:cdef([[
		typedef struct git_submodule git_submodule;
		typedef struct git_repository git_repository;
		int git_submodule_foreach(git_repository *repo, int (*cb)(git_submodule *sm, const char *name, void *payload), void *payload);
	]])
end)

test.it("typedef struct then function using it as pointer param", function()
	local c = ctx()
	c:cdef([[
		typedef struct { long tv_sec; long tv_nsec; } timespec;
		int clock_gettime(int clk_id, timespec *tp);
	]])
	test.equal(c:sizeof("timespec"), ffi.sizeof("long") * 2)
end)

-- resolveTypename: built-in types

test.it("sizeof builtin int passes through", function()
	local c = ctx()
	test.equal(c:sizeof("int"), ffi.sizeof("int"))
end)

test.it("sizeof builtin uint32_t passes through", function()
	local c = ctx()
	test.equal(c:sizeof("uint32_t"), ffi.sizeof("uint32_t"))
end)

test.it("sizeof builtin size_t passes through", function()
	local c = ctx()
	test.equal(c:sizeof("size_t"), ffi.sizeof("size_t"))
end)

test.it("sizeof builtin double passes through", function()
	local c = ctx()
	test.equal(c:sizeof("double"), ffi.sizeof("double"))
end)

test.it("typeof builtin int passes through", function()
	local c = ctx()
	local ct = c:typeof("int")
	test.equal(ffi.sizeof(ct), ffi.sizeof("int"))
end)

-- resolveTypename: const modifier

test.it("cast with const char pointer passes through", function()
	local c = ctx()
	local s = c:cast("const char *", "hello")
	test.equal(ffi.string(s), "hello")
end)

test.it("cast with const user type pointer resolves correctly", function()
	local c = ctx()
	c:cdef("typedef struct { int x; int y; } Vec2;")
	local v = c:new("Vec2", { x = 3, y = 4 })
	local p = c:cast("const Vec2 *", v)
	test.equal(p.x, 3)
	test.equal(p.y, 4)
end)

test.it("cast with const builtin pointer writes through non-const alias", function()
	local c = ctx()
	local n = ffi.new("int[1]", 7)
	local p = c:cast("const int *", n)
	test.equal(p[0], 7)
end)

-- resolveTypename: struct/enum/union keyword prefix

test.it("sizeof struct tag resolves to prefixed tag", function()
	local c = ctx()
	c:cdef("typedef struct Node { int val; struct Node *next; } Node;")
	test.equal(c:sizeof("struct Node"), c:sizeof("Node"))
end)

test.it("cast struct tag pointer resolves to prefixed tag", function()
	local c = ctx()
	c:cdef("typedef struct { int a; int b; } Pair;")
	local p = c:new("Pair", { a = 1, b = 2 })
	local ptr = c:cast("Pair *", p)
	test.equal(ptr.a, 1)
	test.equal(ptr.b, 2)
end)

test.it("sizeof enum tag resolves to prefixed tag", function()
	local c = ctx()
	c:cdef("typedef enum Color { COLOR_RED = 0, COLOR_GREEN = 1 } Color;")
	test.equal(c:sizeof("enum Color"), c:sizeof("Color"))
end)

test.it("typeof struct tag returns usable ctype", function()
	local c = ctx()
	c:cdef("typedef struct { float r; float g; float b; } RGB;")
	local ct = c:typeof("RGB")
	test.equal(ffi.sizeof(ct), ffi.sizeof("float") * 3)
end)

-- resolveTypename: pointer variants

test.it("cast to void pointer resolves correctly", function()
	local c = ctx()
	c:cdef("typedef struct { int v; } Box;")
	local b = c:new("Box", { v = 42 })
	local vp = c:cast("void *", b)
	local p = c:cast("Box *", vp)
	test.equal(p.v, 42)
end)

test.it("new with builtin array type passes through", function()
	local c = ctx()
	local p = c:new("int[4]")
	p[0] = 10
	test.equal(p[0], 10)
end)

-- resolveTypename: error on unknown names

test.it("sizeof unknown type errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:sizeof("NoSuchType") end)
	test.falsy(ok)
	test.truthy(err:find("NoSuchType"))
end)

test.it("typeof unknown type errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:typeof("Phantom") end)
	test.falsy(ok)
	test.truthy(err:find("Phantom"))
end)

test.it("cast unknown base type errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:cast("Ghost *", nil) end)
	test.falsy(ok)
	test.truthy(err:find("Ghost"))
end)

test.it("cast unknown struct tag errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:cast("struct Nope *", nil) end)
	test.falsy(ok)
	test.truthy(err:find("Nope"))
end)

test.it("alignof unknown type errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:alignof("Spooky") end)
	test.falsy(ok)
	test.truthy(err:find("Spooky"))
end)

test.it("offsetof unknown type errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:offsetof("Blorp", "x") end)
	test.falsy(ok)
	test.truthy(err:find("Blorp"))
end)

test.it("unknown type does NOT silently fall through to ffi", function()
	local c1 = ctx()
	local c2 = ctx()
	-- c1 registers the type, c2 never does
	c1:cdef("typedef struct { int x; } Canary;")
	local ok = pcall(function() c2:sizeof("Canary") end)
	test.falsy(ok)  -- c2 must not resolve c1's prefixed name
end)

test.it("const unknown type errors", function()
	local c = ctx()
	local ok, err = pcall(function() c:cast("const Wraith *", nil) end)
	test.falsy(ok)
	test.truthy(err:find("Wraith"))
end)

-- ctype passthrough: all ctx methods accept a ctype object directly

test.it("new with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int x; int y; } Pt;")
	local ct = c:typeof("Pt")
	local p = c:new(ct, { x = 1, y = 2 })
	test.equal(p.x, 1)
	test.equal(p.y, 2)
end)

test.it("sizeof with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int x; int y; } Sz;")
	local ct = c:typeof("Sz")
	test.equal(c:sizeof(ct), ffi.sizeof("int") * 2)
end)

test.it("cast with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int n; } Castable;")
	local ct = c:typeof("Castable")
	local v = c:new("Castable", { n = 7 })
	local p = c:cast(ffi.typeof("$ *", ct), v)
	test.equal(p.n, 7)
end)

test.it("typeof with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { float v; } Flt;")
	local ct = c:typeof("Flt")
	local ct2 = c:typeof(ct)
	test.equal(ffi.sizeof(ct2), ffi.sizeof("float"))
end)

test.it("alignof with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int x; } Aligned;")
	local ct = c:typeof("Aligned")
	test.equal(c:alignof(ct), ffi.alignof("int"))
end)

test.it("offsetof with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int a; int b; } Off;")
	local ct = c:typeof("Off")
	test.equal(c:offsetof(ct, "b"), ffi.sizeof("int"))
end)

test.it("istype with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int x; } Ity;")
	local ct = c:typeof("Ity")
	local v = c:new("Ity")
	test.truthy(c:istype(ct, v))
end)

test.it("metatype with ctype passes through", function()
	local c = ctx()
	c:cdef("typedef struct { int x; } Meta2;")
	local ct = c:typeof("Meta2")
	c:metatype(ct, {
		__index = { doubled = function(self) return self.x * 2 end },
	})
	local v = c:new("Meta2", { x = 5 })
	test.equal(v:doubled(), 10)
end)

-- ctx:load — loaded library proxy

test.it("loaded lib proxy resolves mangled function name", function()
	local c = ctx()
	c:cdef("double sqrt(double x);")
	local lib = c:load("m")
	-- analogous to c.C.strlen: lib.sqrt should resolve via the mangled name
	test.equal(lib.sqrt(4.0), 2.0)
end)

-- resolveTypename: cross-context isolation

test.it("type from one context errors in another context", function()
	local c1 = ctx()
	local c2 = ctx()
	c1:cdef("typedef struct { int x; } Shared;")
	-- c2 never registered Shared, so it must error
	local ok, err = pcall(function() c2:sizeof("Shared") end)
	test.falsy(ok)
	test.truthy(err:find("Shared"))
end)
