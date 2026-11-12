local HttpService = game:GetService("HttpService")

local RAW_URL_FORMAT = "https://raw.githubusercontent.com/%s/%s/%s"
local MAX_ATTEMPTS = 3
local RETRY_DELAY = 1
local HTTP_DISABLED_MARKER = "not enabled"

export type Source = {
	Repository: string,
	Ref: string,
	Path: string,
}

local GitHubLoader = {}

local loadedModules: { [string]: any } = {}

local function isLoadstringAvailable(): boolean
	return loadstring("return true") ~= nil
end

local function fetch(url: string): (boolean, string)
	local lastError = ""

	for attempt = 1, MAX_ATTEMPTS do
		local success, result = pcall(function()
			return HttpService:GetAsync(url, true)
		end)
		if success then
			return true, result
		end

		lastError = tostring(result)
		if string.find(lastError, HTTP_DISABLED_MARKER, 1, true) then
			return false, lastError
		end

		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return false, lastError
end

function GitHubLoader.GetUrl(source: Source): string
	return string.format(RAW_URL_FORMAT, source.Repository, source.Ref, source.Path)
end

function GitHubLoader.Load(source: Source): (boolean, any)
	local url = GitHubLoader.GetUrl(source)

	local cached = loadedModules[url]
	if cached ~= nil then
		return true, cached
	end

	if not isLoadstringAvailable() then
		return false, "LoadStringEnabled is off in this place"
	end

	local fetched, body = fetch(url)
	if not fetched then
		return false, `Could not fetch {url}: {body}`
	end

	local chunk, compileError = loadstring(body, `={source.Repository}/{source.Path}`)
	if not chunk then
		return false, `Could not loadstring {url}: {compileError}`
	end

	local ran, result = pcall(chunk)
	if not ran then
		return false, `Error while running {url}: {result}`
	end

	loadedModules[url] = result
	return true, result
end

return GitHubLoader
