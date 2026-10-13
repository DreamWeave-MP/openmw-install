--!strict
-- The OpenMW context, timed from Luau: opening one, its properties, resolving content files by
-- name (with the data folders listed already, and listing them afresh), the content list, loose
-- assets through the VFS, and activation's check of the data folders. Run by `jess run
-- --capability filesystem.read --capability filesystem.write --package . --package-path ..
-- bench/bench.luau <scratch> [filter]`, on a release build. Prints one line per workload: its
-- name, a tab, and the seconds one call takes. Every workload's result is compared with what the
-- writer of the install says it must be, outside the time, so a path that stopped doing the work
-- fails here.
local configuration = require '@openmw-config'
local fs = require '@dream/fs'
local openmw = require '@openmw'
local vfs = require '@vfs'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error('openmw bench: this jess was built without the verified toolchain: measure on a release build', 0)
end

--- The arguments: a folder to write the install into, and a filter on the workload names.
local scratch: string?, filter: string? = ...
local only = if filter and filter ~= '' then filter else nil

export type Row = { name: string, seconds: number }

local rows: { Row } = {}

local function median(samples: { number }): number
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

--- Seconds per call of `body`: warmed up, then the median of seven batches of a size that takes
--- about a tenth of a second, with a full collection before each so one batch's garbage isn't the
--- next one's. `verify` is given the result of the first call and of one more after the last
--- batch, outside the time.
local function measure(body: () -> unknown, verify: (result: unknown) -> ()): number
  jess.bench.collect()
  verify(body())
  local start = os.clock()
  body()
  local once = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / once))
  local samples: { number } = {}

  for batch = 1, 7 do
    jess.bench.collect()
    start = os.clock()

    for _ = 1, iterations do
      body()
    end

    samples[batch] = (os.clock() - start) / iterations
  end

  verify(body())
  return median(samples)
end

--- Times `body`, whose every result `holds` must accept.
local function workload(name: string, body: () -> unknown, holds: (result: unknown) -> boolean)
  if only and not string.find(name, only, 1, true) then return end

  local function verify(result: unknown)
    if not holds(result) then error(`openmw bench: {name}: the result is not what the install holds`, 0) end
  end

  table.insert(rows, { name = name, seconds = measure(body, verify) })
end

local function io<Value>(value: Value?, message: string?, kind: dream_fs_ErrorKind?): Value
  if not value then error(message or tostring(kind), 0) end

  return value
end

local given: string = assert(scratch, 'openmw bench: the first argument is a scratch folder')
local root = jess.fs.join(io(fs.absolute(given)), 'openmw-bench')

do
  local stale, problem = fs.exists(root)
  if problem then error(problem, 0) end

  if stale then io(fs.remove(root, { recursive = true })) end
end

--- The install as its writer knows it: the data folders in the order the configuration lists
--- them, the path each top-level file name resolves to (the last folder that holds it, whatever
--- the case it is asked for in), and every loose asset below a folder's top level.
local folders: { string }, assets: { string } = {}, {}
local installed: { [string]: string } = {}
local assetPathBytes, assetBytes, topLevelFiles = 0, 0, 0

local function populate(directory: string, files: { string }, below: { string })
  io(fs.mkdir(directory, { recursive = true }))
  table.insert(folders, directory)

  for _, name in files do
    local path = jess.fs.join(directory, name)
    io(fs.writeFile(path, name))
    installed[string.lower(name)] = path
    topLevelFiles += 1
  end

  for _, relative in below do
    local path = jess.fs.join(directory, relative)
    io(fs.mkdir(jess.fs.parent(path) :: string, { recursive = true }))
    io(fs.writeFile(path, relative))
    table.insert(assets, relative)
    assetPathBytes += #path
    assetBytes += #relative
  end
end

local AssetFolders =
  { 'Meshes', 'Textures', 'Icons', 'Sound', 'Music', 'Splash', 'Video', 'BookArt', 'Fonts', 'Shaders', 'MWSE', 'Docs' }

local Masters = { 'Morrowind.esm', 'Tribunal.esm', 'Bloodmoon.esm' }
local Mods = 96
local resources = jess.fs.join(root, 'resources')
local dataFiles = jess.fs.join(root, 'Data Files')
local content: { string }, optional: { string } = table.clone(Masters), {}

--- `name` in one of three cases by `index`: a content line seldom spells a file the way the
--- disk does.
local function spelled(name: string, index: number): string
  if index % 3 == 0 then return string.upper(name) end

  return if index % 3 == 1 then name else string.lower(name)
end

do
  populate(jess.fs.join(resources, 'vfs'), { 'builtin.omwscripts', 'version' }, { 'scripts/omw/camera.lua', 'shaders/water.frag' })

  local files = table.clone(Masters)

  for _, name in { 'Morrowind.bsa', 'Tribunal.bsa', 'Bloodmoon.bsa', 'Morrowind.ini' } do
    table.insert(files, name)
  end

  for index = 1, 233 do
    table.insert(files, `Official Plugin {index}.esp`)
  end

  local below: { string } = {}

  for _, folder in AssetFolders do
    for index = 1, 3 do
      table.insert(below, `{folder}/base_{string.lower(folder)}_{index}.dds`)
    end
  end

  populate(dataFiles, files, below)

  for index = 1, Mods do
    local label = string.format('%03d', index)
    local plugin, addon = `Mod{label}.esp`, `Mod{label}.omwaddon`
    local modFiles = { plugin, `Mod{label} Optional.esp`, `Mod{label} readme.txt` }

    table.insert(content, spelled(plugin, index))
    table.insert(optional, spelled(`Mod{label} Optional.esp`, index + 1))

    if index % 4 == 0 then
      table.insert(modFiles, addon)
      table.insert(content, spelled(addon, index))
    end

    -- Two folders hold this one: the later folder's is the file the name resolves to.
    if index == 10 or index == 50 then table.insert(modFiles, 'Shared Patch.esp') end

    populate(
      jess.fs.join(root, 'mods', `mod-{label}`),
      modFiles,
      { `textures/mod{label}_a.dds`, `textures/mod{label}_b.dds`, `meshes/mod{label}.nif` }
    )
  end

  table.insert(content, 'shared patch.esp')

  for index = 1, 4 do
    table.insert(content, `Missing {index}.esp`)
  end
end

local configPath = jess.fs.join(root, 'config', 'openmw.cfg')

do
  local lines = { 'encoding=win1252', `resources="{resources}"` }

  for index = 2, #folders do
    table.insert(lines, `data="{folders[index]}"`)
  end

  for _, name in content do
    table.insert(lines, `content={name}`)
  end

  io(fs.mkdir(jess.fs.parent(configPath) :: string, { recursive = true }))
  io(fs.writeFile(configPath, table.concat(lines, '\n') .. '\n'))
end

local config = configuration.new(configPath)
local context = openmw.fromConfig(config)
local same = all[for folder, listed in zipStrict(folders, context.dataDirs) => folder == listed]

assert(same, 'openmw bench: the configuration does not list the folders that were written')

local function resolvedPath(name: string): string? return installed[string.lower(name)] end

workload(
  `new: a configuration of {#folders} data folders and {#content} content files`,
  function(): unknown return openmw.new(configPath) end,
  function(result: unknown): boolean
    local opened = result :: openmw.Context
    return opened.userConfigDir == jess.fs.parent(configPath) and #opened:configuration():values('content') == #content
  end
)

workload(
  'fromConfig: a context over a loaded configuration',
  function(): unknown return openmw.fromConfig(config) end,
  function(result: unknown): boolean return (result :: openmw.Context):configuration() == config end
)

workload(
  'properties: the six, read once each',
  function(): unknown
    local total = #context.dataDirs + #context.fallbackArchives + #context.userConfigDir
    return total + #(context.encoding or '') + #(context.dataLocal or '') + #(context.writableDataDir or '')
  end,
  function(result: unknown): boolean
    return result == #folders + #(jess.fs.parent(configPath) :: string) + #'win1252' + #dataFiles
  end
)

do
  local lookups: { string } = {}

  for index, name in content do
    table.insert(lookups, name)
    table.insert(lookups, spelled(name, index + 1))
  end

  local bytes = sum[for name in lookups => #(resolvedPath(name) or '')]

  workload(
    `resolve: {#lookups} content file names, the folders listed already`,
    function(): unknown return sum[for name in lookups => #(context:resolve(name) or '')] end,
    function(result: unknown): boolean return result == bytes end
  )
end

workload(
  `resolve: one name, listing {#folders} folders of {topLevelFiles} files afresh`,
  function(): unknown
    context:refresh()
    return context:resolve('MORROWIND.ESM')
  end,
  function(result: unknown): boolean return result == jess.fs.join(dataFiles, 'Morrowind.esm') end
)

local function isContent(result: unknown): boolean
  local entries = result :: { openmw.ContentEntry }
  if #entries ~= #content then return false end

  return all[for entry, name in zipStrict(entries, content) => entry.name == name and entry.path == resolvedPath(name)]
end

workload(
  `content: {#content} files, the folders listed already`,
  function(): unknown return context:content() end,
  isContent
)

workload(
  `content: {#content} files, listing {#folders} folders afresh`,
  function(): unknown
    context:refresh()
    return context:content()
  end,
  isContent
)

workload(
  `resolve: {#assets} loose assets below the top level, the VFS built already`,
  function(): unknown return sum[for path in assets => #(context:resolve(path) or '')] end,
  function(result: unknown): boolean return result == assetPathBytes end
)

workload(
  `readFile: {#assets} loose assets, the VFS built already`,
  function(): unknown
    local total = 0

    for _, path in assets do
      local bytes = context:readFile(path)
      if bytes then total += buffer.len(bytes) end
    end

    return total
  end,
  function(result: unknown): boolean return result == assetBytes end
)

workload(
  `vfs: {#folders} folders, no archive`,
  function(): unknown return context:vfs() end,
  function(result: unknown): boolean
    local file = (result :: vfs.VFS):getFile(assets[#assets])
    return file ~= nil and file:path() == jess.fs.join(folders[#folders], assets[#assets])
  end
)

do
  local absent = 'No Such Plugin.esp'

  workload(
    `activate: refuses a name none of {#folders} folders holds`,
    function(): unknown
      -- `context:activate` throws on a name no data folder holds, which is the check this times.
      local _, message = pcall(context.activate, context, absent)
      return message
    end,
    function(result: unknown): boolean
      return type(result) == 'string' and string.find(result, "isn't in the data folders", 1, true) ~= nil
    end
  )

  local batch: { string } = {}

  for index = 3, Mods, 3 do
    table.insert(batch, optional[index])
  end

  table.insert(batch, absent)

  workload(
    `activateAll: checks {#batch} names and refuses the last`,
    function(): unknown
      -- `context:activateAll` checks every name before it activates any, and throws on the last.
      local _, message = pcall(context.activateAll, context, batch)
      return message
    end,
    function(result: unknown): boolean
      local refused = type(result) == 'string' and string.find(result, absent, 1, true) ~= nil
      return refused and #config:values('content') == #content
    end
  )

  table.remove(batch)

  workload(
    `activateAll and deactivate: {#batch} plugins`,
    function(): unknown
      local added = #context:activateAll(batch)
      return added + #[for name in batch if context:deactivate(name) => name]
    end,
    function(result: unknown): boolean return result == 2 * #batch and #config:values('content') == #content end
  )

  workload(
    'activate and deactivate: a plugin in the last folder',
    function(): unknown return context:activate(optional[Mods]) and context:deactivate(optional[Mods]) end,
    function(result: unknown): boolean return result == true and #config:values('content') == #content end
  )

  workload(
    'activate: a name already active',
    function(): unknown return context:activate('morrowind.ESM') end,
    function(result: unknown): boolean return result == false end
  )

  workload(
    'deactivate: a name not active',
    function(): unknown return context:deactivate(absent) end,
    function(result: unknown): boolean return result == false end
  )
end

io(fs.remove(root, { recursive = true }))

for _, row in rows do
  print(`{row.name}\t{string.format('%.9f', row.seconds)}`)
end

return rows
