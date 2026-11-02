local pkg = require("aqua.pkg")

pkg.add() -- Root folder
pkg.add("aqua")
pkg.add("3rd-deps/lua")
pkg.add("tree/share/lua/5.1")

pkg.addc("bin/linux64")
pkg.addc("tree/lib/lua/5.1")

local or_root = os.getenv("OR_ROOT")
if or_root then
	pkg.add(or_root .. "/lualib")
end

pkg.export_lua()
