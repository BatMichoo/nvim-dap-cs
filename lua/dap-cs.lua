--- @module 'nvim-dap-cs'
--- @brief A Neovim plugin for debugging C# projects with `netcoredbg`.
---
--- This module provides an intelligent set of debug configurations for C# projects,
--- including automatically selecting and attaching to .NET processes.
local M = {}

local default_config = {
	netcoredbg = {
		path = "netcoredbg",
	},
}

--- @brief A helper function to safely load a Neovim module.
--- @param module_name string The name of the module to load, e.g., 'dap'.
--- @return table module The loaded module.
--- @throws An error if the module is not found.
local load_module = function(module_name)
	local ok, module = pcall(require, module_name)
	assert(ok, string.format("dap-cs dependency error: %s not installed", module_name))
	return module
end

--- @brief Prepends a numerical index and the file name (without extension) to each entry in an array of file paths.
--- @param array string[] A list of file paths.
--- @return string[] result A new list with numerically indexed file names.
local number_indicies = function(array)
	local result = {}
	for i, value in ipairs(array) do
		result[i] = i .. ": " .. vim.fn.fnamemodify(value, ":t:r")
	end
	return result
end

--- @brief Presents a numbered list of options to the user for selection via a Neovim input list.
--- @param prompt_title string The title to display at the top of the list.
--- @param options string[] The list of options the user can choose from.
--- @return string|nil choice The selected option or nil if the user cancels.
local display_selection = function(prompt_title, options)
	local display_list = number_indicies(options)
	table.insert(display_list, 1, prompt_title)

	local choice = vim.fn.inputlist(display_list)

	if choice > 0 then
		return options[choice]
	else
		return nil
	end
end

--- @brief Executes a shell command and presents the results to the user for selection.
--- @param cmd string The shell command to execute.
--- @param opts table A table of options to customize behavior.
--- @param opts.empty_message string The message to print if no files are found.
--- @param opts.title_message string The title for the selection list if multiple results are found.
--- @param opts.allow_multiple boolean If true, returns all results without prompting for selection.
--- @return string|string[]|nil result The selected file path, a list of file paths if `allow_multiple` is true, or nil.
local select_file = function(cmd, opts)
	local results = vim.fn.systemlist(cmd)

	if #results == 0 then
		print(opts.empty_message)
		return
	end

	if opts.allow_multiple then
		return results
	end

	local result = results[1]
	if #results > 1 then
		result = display_selection(opts.title_message, results)
	end

	return result
end

--- @brief Searches for C# project files in a given directory and prompts the user for a selection if needed.
--- @param cwd string The directory to search in.
--- @param allow_multiple boolean If true, returns all found project files instead of a single selection.
--- @return string|string[]|nil project_file The selected project file path(s) or nil.
local select_project = function(cwd, allow_multiple)
	local check_csproj_cmd = string.format('find %s -type f -name "*.csproj"', cwd)

	local project_file = select_file(check_csproj_cmd, {
		empty_message = "No csproj files found in " .. cwd,
		title_message = "Select .NET Project:",
		allow_multiple = allow_multiple,
	})

	return project_file
end

--- @brief Finds and selects a .NET DLL for a project in the current working directory.
--- This function first selects a project and then locates its corresponding DLL in the `bin` folder.
--- @return string|nil dll_path The path to the selected DLL or nil if no DLL is found.
--- @return string|nil project_path The path to the project directory or nil if no DLL is found.
local select_dll = function()
	local cwd = vim.fn.getcwd()
	local project_file = select_project(cwd)

	if project_file == nil then
		return
	end

	local project_name = vim.fn.fnamemodify(project_file, ":t:r")
	local project_path = vim.fn.fnamemodify(project_file, ":h")

	local bin_path = project_path .. "/bin"
	local check_net_folders_cmd = string.format('find %s -maxdepth 2 -type d -name "net*"', bin_path)

	local net_bin = select_file(check_net_folders_cmd, {
		empty_message = 'No dotnet DLLs found in the "bin" directory. Ensure project has been built.',
		title_message = "Select .NET Version:",
	})

	if net_bin == nil then
		return
	end

	local dll_path = net_bin .. "/" .. project_name .. ".dll"
	return dll_path, project_path
end

--- @brief Attempts to pick a process smartly.
---
--- Does the following:
--- 1. Gets all project files
--- 2. Build filter
--- 2a. If a single project is found then will filter for processes ending with project name.
--- 2b. If multiple projects found then will filter for processes ending with any of the project file names.
--- 2c. If no project files found then will filter for processes starting with "dotnet"
--- 3. If a single process matches then auto selects it. If multiple found then displays it user for selection.
--- @param dap_utils table The `dap.utils` module containing helper functions.
--- @param cwd string The current working directory.
--- @return number|nil ID The PID of the selected process or nil if no process is found.
local smart_pick_process = function(dap_utils, cwd)
	local project_file = select_project(cwd, true)
	if project_file == nil then
		return
	end

	local filter = function(proc)
		if type(project_file) == "table" then
			for _, file in pairs(project_file) do
				local project_name = vim.fn.fnamemodify(file, ":t:r")
				if vim.endswith(proc.name, project_name) then
					return true
				end
			end
			return false
		elseif type(project_file) == "string" then
			local project_name = vim.fn.fnamemodify(project_file, ":t:r")
			return vim.startswith(proc.name, project_name or "dotnet")
		end
	end

	local processes = dap_utils.get_processes()
	processes = vim.tbl_filter(filter, processes)

	if #processes == 0 then
		print("No dotnet processes could be found automatically. Try 'Attach' instead")
		return
	end

	if #processes > 1 then
		return dap_utils.pick_process({
			filter = filter,
		})
	end

	return processes[1].pid
end

--- @brief Sets up the coreclr debug configurations for C# in Neovim's DAP.
--- It defines "Launch Project", "Attach to Process", and "Smart Attach" configurations.
--- @param dap table The `dap` module.
--- @param dap_utils table The `dap.utils` module.
--- @param config table The plugin configuration table.
local setup_configuration = function(dap, dap_utils, config)
	dap.configurations.cs = {
		setmetatable({
			type = "coreclr",
			name = "Launch Project",
			request = "launch",
			program = "${file}",
			env = {
				ASPNETCORE_ENVIRONMENT = "Development",
			},
			cwd = "${fileDirname}",
		}, {
			__call = function(config)
				local dll_path, project_path = select_dll()
				config.cwd = project_path
				config.program = dll_path or dap.ABORT
				return config
			end,
		}),
		{
			type = "coreclr",
			name = "Attach to Process",
			request = "attach",
			processId = dap_utils.pick_process,
		},
		{
			type = "coreclr",
			name = "Smart Attach",
			request = "attach",
			processId = function()
				local current_working_dir = vim.fn.getcwd()
				return smart_pick_process(dap_utils, current_working_dir) or dap.ABORT
			end,
		},
	}

	if config == nil or config.dap_configurations == nil then
		return
	end

	for _, dap_config in ipairs(config.dap_configurations) do
		if dap_config.type == "coreclr" then
			table.insert(dap.configurations.cs, dap_config)
		end
	end
end

--- @brief Sets up the `coreclr` debug adapter for Neovim's DAP.
--- @param dap table The `dap` module.
--- @param config table The plugin configuration table, including the path to `netcoredbg`.
local setup_adapter = function(dap, config)
	dap.adapters.coreclr = {
		type = "executable",
		command = config.netcoredbg.path,
		args = { "--interpreter=vscode" },
	}
end

--- @brief The main entry point for setting up the debugger plugin.
--- This function merges user options with defaults, loads dependencies, and sets up the DAP adapter and configurations.
--- @param opts table A table of user options to override the defaults.
function M.setup(opts)
	local config = vim.tbl_deep_extend("force", default_config, opts or {})
	local dap = load_module("dap")
	local dap_utils = load_module("dap.utils")
	setup_adapter(dap, config)
	setup_configuration(dap, dap_utils, config)
end

return M
