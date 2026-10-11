--!strict
--!native
local configuration = require '@openmw-config'
local openmw = require '@openmw'
local fs = require '@dream/fs'
local archive = require '@dream-archive'
local vfs = require '@vfs'
local test = require '@jess/test'

local expect = test.expect
local suite = test.new()
local scratch = assert(rawget(_G, 'scratchRoot') :: string?, 'the suite needs a host-owned scratchRoot')

local function io<Value>(value: Value?, message: string?, kind: dream_fs_ErrorKind?): Value
  if not value then error(message or tostring(kind), 0) end

  return value
end

local function fixture(name: string, source: string): (string, string)
  local directory = jess.fs.join(scratch, 'openmw-config', name)
  io(fs.mkdir(directory, { recursive = true }))
  local path = jess.fs.join(directory, 'openmw.cfg')
  io(fs.writeFile(path, source))
  return directory, path
end

local function read(path: string): string return io(fs.readFileString(path)) end

suite.describe('configuration ownership', function()
  suite.it('returns detached entry and chain snapshots', function()
    local _, path = fixture('snapshots', 'content=Keep.esm\n')
    local config = configuration.new(path)
    config:entries()[1].value = 'Changed.esp'
    config:chain()[1].path = 'not-the-config'
    expect(config:values('content')).toEqual { 'Keep.esm' }
    expect(config:chain()[1].path).toBe(path)
    expect(table.isfrozen(config)).toBe(true)
    expect(function() vfs.serialize({ document = config }, 'json') end).toThrow 'function'
  end)
end)

suite.describe('explicit OpenMW context', function()
  suite.it('reads archived assets but never activates archived content files', function()
    local directory, path = fixture('archive-assets', 'data=data\nfallback-archive=Example.bsa\n')
    local data = jess.fs.join(directory, 'data')
    io(fs.mkdir(data, { recursive = true }))
    local builder = archive.bsa.tes3.Builder.new()
    builder:addBytes('textures/example.dds', 'archived texture')
    builder:addBytes('Hidden.esp', 'archived content')
    builder:writePath(jess.fs.join(data, 'Example.bsa'))
    local context = openmw.new(path)
    expect(buffer.tostring(context:readFile('textures/example.dds') :: buffer)).toBe 'archived texture'
    expect(context:resolve('Hidden.esp')).toBeNil()
    expect(function() context:activate('Hidden.esp') end).toThrow "isn't in the data folders"
    expect(table.isfrozen(context)).toBe(true)
    expect(function() vfs.serialize({ context = context }, 'json') end).toThrow 'function'
  end)

  suite.it('checks every activation before mutating and checks newly written files afresh', function()
    local directory, path = fixture('activation', 'data=data\ncontent=Missing.esm\n')
    local data = jess.fs.join(directory, 'data')
    io(fs.mkdir(data, { recursive = true }))
    io(fs.writeFile(jess.fs.join(data, 'Mine.esp'), ''))
    local context = openmw.new(path)
    expect(function() context:activateAll({ 'Mine.esp', 'Typo.esp' }) end).toThrow "isn't in the data folders"
    expect(context:configuration():values('content')).toEqual { 'Missing.esm' }
    expect(context:activate('MISSING.ESM')).toBe(false)
    expect(context:activate('mine.esp')).toBe(true)
    expect(context:activate('MINE.ESP')).toBe(false)
    io(fs.writeFile(jess.fs.join(data, 'Late.esp'), ''))
    expect(context:activate('late.esp')).toBe(true)
    expect(context:deactivate('MINE.ESP')).toBe(true)
  end)

  suite.it('invalidates lookup caches when configuration changes', function()
    local directory, path = fixture('invalidation', 'data=first\n')
    for _, folder in { 'first', 'second' } do
      io(fs.mkdir(jess.fs.join(directory, folder), { recursive = true }))
      io(fs.writeFile(jess.fs.join(directory, folder, 'Example.esp'), folder))
    end

    local context = openmw.new(path)
    expect(context:resolve('example.esp')).toBe(jess.fs.join(directory, 'first/Example.esp'))
    context:configuration():replace('data', { 'second' })
    expect(context:resolve('EXAMPLE.ESP')).toBe(jess.fs.join(directory, 'second/Example.esp'))
    expect(buffer.tostring(context:readFile('example.esp') :: buffer)).toBe 'second'
    context.dataDirs[1] = 'not-a-data-folder'
    expect(context.dataDirs[1]).toBe(jess.fs.join(directory, 'second'))
    context:configuration():set('resources', 'resources')
    context:configuration():replace('data', { 'resources/vfs', 'second' })
    expect(context.writableDataDir).toBe(jess.fs.join(directory, 'second'))
  end)

  suite.it('backs up the user bytes and skips existing backup names', function()
    local source = '# original\r\ncontent=Keep.esm\r\n'
    local _, path = fixture('backups', source)
    io(fs.writeFile(path .. '.bak', 'older'))
    local context = openmw.new(path)
    context:activate('Forced.esp', { force = true })
    local written = context:save()
    expect(written.backup).toBe(path .. '.bak1')
    expect(read(written.backup :: string)).toBe(source)
    expect(read(path .. '.bak')).toBe 'older'
    expect(configuration.new(path):values('content')).toEqual { 'Keep.esm', 'Forced.esp' }
  end)
end)

return suite
