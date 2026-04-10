local process = require("@lune/process")
local fs = require("@lune/fs")

if not fs.isDir("dist") then
	fs.writeDir("dist")
end

-- Bundle + minify
local minified = process.exec("darklua", { "process", "src/init.luau", "dist/RegExp.luau" })
if not minified.ok then
	print("minified build failed:")
	print(minified.stderr)
	process.exit(1)
end

-- Bundle + readable
local readable = process.exec("darklua", {
	"process",
	"src/init.luau",
	"dist/RegExp.readable.luau",
	"--format",
	"readable",
})
if not readable.ok then
	print("readable build failed:")
	print(readable.stderr)
	process.exit(1)
end

local Header = fs.readFile("header.luau")

local minifiedSrc = fs.readFile("dist/RegExp.luau")
local readableSrc = fs.readFile("dist/RegExp.readable.luau")

minifiedSrc = Header .. minifiedSrc
readableSrc = Header .. readableSrc

fs.writeFile("dist/RegExp.luau", minifiedSrc)
fs.writeFile("dist/RegExp.readable.luau", readableSrc)

print(string.format("dist/RegExp.luau          %5.1f KB (minified)", #minifiedSrc / 1024))
print(string.format("dist/RegExp.readable.luau %5.1f KB (readable)", #readableSrc / 1024))
