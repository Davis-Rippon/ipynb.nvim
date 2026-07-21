-- ipynb/images.lua - Image output rendering using image.nvim

local M = {}

--------------------------------------------------------------------------------
-- Namespace for our image extmarks
--------------------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("ipynb_images")
M.ns = ns

--------------------------------------------------------------------------------
-- MIME Type Definitions
--------------------------------------------------------------------------------

local MIME_EXTENSIONS = {
	["image/png"] = "png",
	["image/jpeg"] = "jpg",
	["image/gif"] = "gif",
	["image/webp"] = "webp",
	["image/bmp"] = "bmp",
	["image/tiff"] = "tiff",
	["image/heic"] = "heic",
	["image/avif"] = "avif",
	["image/svg+xml"] = "svg",
	["application/pdf"] = "pdf",
}

local TEXT_MIME_TYPES = {
	["image/svg+xml"] = true,
}

local image_nvim_available = nil

--------------------------------------------------------------------------------
-- File I/O helpers
--------------------------------------------------------------------------------

local function get_cache_dir()
	local config = require("ipynb.config").get()
	local dir = config.images and config.images.cache_dir or (vim.fn.stdpath("cache") .. "/ipynb.nvim")
	vim.fn.mkdir(dir, "p")
	return dir
end

local function base64_decode(data)
	if vim.base64 and vim.base64.decode then
		local ok, decoded = pcall(vim.base64.decode, data)
		if ok then
			return decoded
		end
	end
	return nil
end

local function write_binary_file(path, data)
	local uv = vim.uv or vim.loop
	local fd = uv.fs_open(path, "w", 438)
	if not fd then
		return false
	end

	local ok_write = uv.fs_write(fd, data, 0)
	uv.fs_close(fd)
	return ok_write ~= nil
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.is_available()
	local config = require("ipynb.config").get()
	if config.images and config.images.enabled == false then
		return false
	end

	if image_nvim_available == true then
		return true
	end

	local ok, _ = pcall(require, "image")
	if not ok then
		return false
	end

	image_nvim_available = true
	return true
end

function M.supports_placeholders()
	return M.is_available()
end

function M.get_image_data(output)
	if output.output_type ~= "execute_result" and output.output_type ~= "display_data" then
		return false, nil, nil, false
	end

	local data = output.data
	if not data then
		return false, nil, nil, false
	end

	for mime, _ in pairs(MIME_EXTENSIONS) do
		if data[mime] then
			local image_data = data[mime]
			if type(image_data) == "table" then
				image_data = table.concat(image_data, "")
			end
			local is_text = TEXT_MIME_TYPES[mime] or false
			return true, mime, image_data, is_text
		end
	end

	return false, nil, nil, false
end

function M.get_image_virt_lines(state, cell, output, image_index)
	if not M.is_available() then
		return nil, 0
	end

	local has_image, mime, image_data, is_text = M.get_image_data(output)
	if not has_image or not mime or not image_data then
		return nil, 0
	end

	local image_api = require("image")
	local cell_id = cell.id
	if not cell_id then
		return nil, 0
	end

	local file_content
	if is_text then
		file_content = image_data
	else
		file_content = base64_decode(image_data)
	end

	if not file_content then
		return nil, 0
	end

	local cache_dir = get_cache_dir()
	local ext = MIME_EXTENSIONS[mime] or "png"
	local data_hash = vim.fn.sha256(image_data):sub(1, 12)
	local filename = string.format("%s-%d-%s.%s", cell_id, image_index, data_hash, ext)
	local path = cache_dir .. "/" .. filename

	if not write_binary_file(path, file_content) then
		return nil, 0
	end

	local facade_win = nil
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == state.facade_buf then
			facade_win = win
			break
		end
	end

	local config = require("ipynb.config").get()
	local img_config = config.images or {}

	local width_padding = 2
	local height_padding = 1

	local text_width, max_img_height
	if facade_win then
		local wininfo = vim.fn.getwininfo(facade_win)[1]
		text_width = vim.api.nvim_win_get_width(facade_win) - (wininfo and wininfo.textoff or 0) - width_padding
		max_img_height = img_config.max_height
			or (vim.api.nvim_win_get_height(facade_win) - vim.wo[facade_win].scrolloff - height_padding)
	else
		text_width = vim.o.columns - width_padding
		max_img_height = img_config.max_height or (vim.o.lines - height_padding)
	end

	-- Let image.nvim handle virtual padding natively so it forces code to push down cleanly
	local img = image_api.from_file(path, {
		id = string.format("%s_%d", cell_id, image_index),
		window = facade_win,
		buffer = state.facade_buf,
		with_virtual_padding = true, 
		max_width = text_width,
		max_height = max_img_height,
		inline = true,
	})

	if not img then
		return nil, 0
	end

	-- Request rendering through image.nvim
	pcall(function()
		img:render()
	end)

	-- Retrieve the calculated layout dimensions directly from image.nvim instance metadata
	local img_height = img.window_height or 1
	local img_width = img.window_width or text_width

	-- Provide exact structural rows for the caller plugin hook layout tracking
	local virt_line_entries = {}
	local blank_row = string.rep(" ", math.min(img_width, text_width))
	for _ = 1, img_height do
		table.insert(virt_line_entries, { { blank_row, "Normal" } })
	end

	state.images = state.images or {}
	state.images[cell_id] = state.images[cell_id] or {}
	table.insert(state.images[cell_id], {
		img = img,
		path = path,
	})

	return virt_line_entries, img_height
end

function M.clear_images(state, cell_id)
	if not state.images or not state.images[cell_id] then
		return
	end

	for _, entry in ipairs(state.images[cell_id]) do
		if entry.path then
			pcall(vim.fn.delete, entry.path)
		end
		if entry.img then
			pcall(function()
				entry.img:clear()
			end)
		end
	end

	state.images[cell_id] = nil
end

function M.clear_all_images(state)
	if not state.images then
		return
	end

	for cell_id, _ in pairs(state.images) do
		M.clear_images(state, cell_id)
	end

	state.images = {}
end

function M.sync_positions(state)
	if not state.images then
		return
	end
	
	for _, cell_images in pairs(state.images) do
		for _, entry in ipairs(cell_images) do
			if entry.img then
				pcall(function()
					entry.img:render()
				end)
			end
		end
	end
end

return M
