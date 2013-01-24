--[[
Policy file handling for Alpine Wall
Copyright (C) 2012-2013 Kaarle Ritvanen
Licensed under the terms of GPL2
]]--

module(..., package.seeall)

require 'json'
require 'lfs'
require 'lpc'

require 'awall.dependency'
require 'awall.object'
require 'awall.util'

local util = awall.util


local PolicyConfig = awall.object.class()

function PolicyConfig:init(data, source, policies)
   self.data = data
   self.source = source
   self.policies = policies
end

function PolicyConfig:expand()

   local function expand(value)
      if type(value) == 'table' then return util.map(value, expand) end

      local visited = {}
      local pattern = '%$(%a[%w_]*)'
      
      while type(value) == 'string' and string.find(value, pattern) do
	 local si, ei, name = string.find(value, pattern)
	 
	 if util.contains(visited, name) then
	    error('Circular variable definition: '..name)
	 end
	 table.insert(visited, name)
	 
	 local var = self.data.variable[name]
	 if not var then error('Invalid variable reference: '..name) end
	 
	 if si == 1 and ei == string.len(value) then value = var
	 elseif util.contains({'number', 'string'}, type(var)) then
	    value = string.sub(value, 1, si - 1)..var..string.sub(value, ei + 1, -1)
	 else
	    error('Attempted to concatenate complex variable: '..name)
	 end
      end

      if value == '' then return end
      return value
   end

   return expand(self.data)
end



local function open(name, dirs)
   if not string.match(name, '^[%w-]+$') then
      error('Invalid characters in policy name: '..name)
   end
   for i, dir in ipairs(dirs) do
      local path = dir..'/'..name..'.json'
      file = io.open(path)
      if file then return file, path end
   end
end

local function find(name, dirs)
   local file, path = open(name, dirs)
   if file then file:close() end
   return path
end

local function list(dirs)
   local allnames = {}
   local res = {}

   for i, dir in ipairs(dirs) do
      local names = {}
      local paths = {}

      for fname in lfs.dir(dir) do
	 local si, ei, name = string.find(fname, '^([%w-]+)%.json$')
	 if name then
	    if util.contains(allnames, name) then
	       error('Duplicate policy name: '..name)
	    end
	    table.insert(allnames, name)

	    table.insert(names, name)
	    paths[name] = dir..'/'..fname
	 end
      end

      table.sort(names)
      for i, name in ipairs(names) do
	 table.insert(res, {name, paths[name]})
      end
   end

   return res
end


PolicySet = awall.object.class()

function PolicySet:init(confdirs, importdirs)
   self.autodirs = confdirs or {'/usr/share/awall/mandatory', '/etc/awall'}
   self.confdir = self.autodirs[#self.autodirs]
   self.importdirs = importdirs or {'/usr/share/awall/optional',
				    '/etc/awall/optional'}
end


function PolicySet:loadJSON(name, fname)
   local file
   if fname then
      file = io.open(fname)
   else
      file, fname = open(name, self.importdirs)
   end
   if not file then error('Unable to read policy file '..fname) end

   local data = ''
   for line in file:lines() do data = data..line end
   file:close()

   local success, res = pcall(json.decode, data)
   if success then return res end
   error(res..' while parsing '..fname)
end


function PolicySet:load()
   
   local policies = {}

   local function require(name, fname)
      if policies[name] then return end

      local policy = self:loadJSON(name, fname)
      policies[name] = policy

      if not policy.after then policy.after = policy.import end
      for i, iname in util.listpairs(policy.import) do require(iname) end
   end

   for i, pol in ipairs(list(self.autodirs)) do require(unpack(pol)) end


   local order = awall.dependency.order(policies)
   if type(order) ~= 'table' then
      error('Circular ordering directives: '..order)
   end


   local input = {}
   local source = {}

   for i, name in ipairs(order) do
      for cls, objs in pairs(policies[name]) do
	 if not util.contains({'description', 'import', 'after', 'before'},
			      cls) then
	    if not source[cls] then source[cls] = {} end

	    if not input[cls] then
	       input[cls] = objs
	       for k, v in pairs(objs) do source[cls][k] = name end

	    elseif objs[1] then
	       local last = #input[cls]
	       util.extend(input[cls], objs)
	       for i = 1,#objs do source[cls][last + i] = name end

	    else
	       for k, v in pairs(objs) do
		  input[cls][k] = v
		  source[cls][k] = name
	       end
	    end
	 end
      end
   end

   return PolicyConfig.new(input, source, util.keys(policies))
end


function PolicySet:findsymlink(name)
   local symlink = find(name, {self.confdir})
   if symlink and lfs.symlinkattributes(symlink).mode ~= 'link' then
      error('Not an optional policy: '..name)
   end
   return symlink
end

function PolicySet:enable(name)
   if self:findsymlink(name) then error('Policy already enabled: '..name)
   else
      local target = find(name, self.importdirs)
      if not target then error('Policy not found: '..name) end
      if string.sub(target, 1, 1) ~= '/' then
	 target = lfs.currentdir()..'/'..target
      end

      local pid, stdin, stdout = lpc.run('ln', '-s', target, self.confdir)
      stdin:close()
      stdout:close()
      assert(lpc.wait(pid) == 0)
   end
end

function PolicySet:disable(name)
   local symlink = self:findsymlink(name)
   if not symlink then error('Policy not enabled: '..name) end
   assert(os.remove(symlink))
end

function PolicySet:list()
   local imported = self:load().policies
   local res = {}

   for i, pol in ipairs(list(self.importdirs)) do
      local name = pol[1]

      local status
      if self:findsymlink(name) then status = 'enabled'
      elseif util.contains(imported, name) then status = 'required'
      else status = 'disabled' end

      table.insert(res,
		   {name, status, self:loadJSON(name, pol[2]).description})
   end

   return res
end
