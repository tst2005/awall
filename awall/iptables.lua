--[[
Iptables file dumper for Alpine Wall
Copyright (C) 2012-2014 Kaarle Ritvanen
See LICENSE file for license details
]]--


local class = require('awall.class')
local raise = require('awall.uerror').raise

local util = require('awall.util')
local sortedkeys = util.sortedkeys


local mkdir = require('posix').mkdir
local lpc = require('lpc')


local M = {}

local families = {inet={cmd='iptables',
			file='rules-save',
			procfile='/proc/net/ip_tables_names'},
		  inet6={cmd='ip6tables',
			 file='rules6-save',
			 procfile='/proc/net/ip6_tables_names'}}

M.builtin = {
   filter={'FORWARD', 'INPUT', 'OUTPUT'},
   mangle={'FORWARD', 'INPUT', 'OUTPUT', 'POSTROUTING', 'PREROUTING'},
   nat={'INPUT', 'OUTPUT', 'POSTROUTING', 'PREROUTING'},
   raw={'OUTPUT', 'PREROUTING'},
   security={'FORWARD', 'INPUT', 'OUTPUT'}
}

local backupdir = '/var/run/awall'


local BaseIPTables = class()

function BaseIPTables:print()
   for _, family in sortedkeys(families) do
      self:dumpfile(family, io.output())
      io.write('\n')
   end
end

function BaseIPTables:dump(dir)
   for family, tbls in pairs(families) do
      local file = io.open(dir..'/'..families[family].file, 'w')
      self:dumpfile(family, file)
      file:close()
   end
end

function BaseIPTables:restore(test)
   local disabled = true

   for family, params in pairs(families) do
      local file = io.open(params.procfile)
      if file then
	 io.close(file)

	 local pid, stdin, stdout = lpc.run(
	    params.cmd..'-restore', table.unpack{test and '-t' or nil}
	 )
	 stdout:close()
	 self:dumpfile(family, stdin)
	 stdin:close()
	 assert(lpc.wait(pid) == 0)

	 disabled = false

      elseif test then
	 io.stderr:write('Warning: '..family..' rules not tested\n')
      end
   end

   if disabled then raise('Firewall not enabled in kernel') end
end

function BaseIPTables:activate()
   M.flush()
   self:restore(false)
end

function BaseIPTables:test() self:restore(true) end


M.IPTables = class(BaseIPTables)

function M.IPTables:init()
   self.config = {}
   setmetatable(self.config,
		{__index=function(t, k)
			    t[k] = {}
			    setmetatable(t[k], getmetatable(t))
			    return t[k]
			 end})
end

function M.IPTables:dumpfile(family, iptfile)
   iptfile:write('# '..families[family].file..' generated by awall\n')
   local tables = self.config[family]
   for i, tbl in sortedkeys(tables) do
      iptfile:write('*'..tbl..'\n')
      local chains = tables[tbl]
      for i, chain in sortedkeys(chains) do
	 local policy = '-'
	 if util.contains(M.builtin[tbl], chain) then
	    policy = tbl == 'filter' and 'DROP' or 'ACCEPT'
	 end
	 iptfile:write(':'..chain..' '..policy..' [0:0]\n')
      end
      for i, chain in sortedkeys(chains) do
	 for i, rule in ipairs(chains[chain]) do
	    iptfile:write('-A '..chain..' '..rule..'\n')
	 end
      end
      iptfile:write('COMMIT\n')
   end
end


local Current = class(BaseIPTables)

function Current:dumpfile(family, iptfile)
   local pid, stdin, stdout = lpc.run(families[family].cmd..'-save')
   stdin:close()
   for line in stdout:lines() do iptfile:write(line..'\n') end
   stdout:close()
   assert(lpc.wait(pid) == 0)
end


local Backup = class(BaseIPTables)

function Backup:dumpfile(family, iptfile)
   for line in io.lines(backupdir..'/'..families[family].file) do
      iptfile:write(line..'\n')
   end
end


function M.backup()
   mkdir(backupdir)
   Current():dump(backupdir)
end

function M.revert() Backup():activate() end

function M.flush()
   local empty = M.IPTables()
   for family, params in pairs(families) do
      local success, lines = pcall(io.lines, params.procfile)
      if success then
	 for tbl in lines do
	    if M.builtin[tbl] then
	       for i, chain in ipairs(M.builtin[tbl]) do
		  empty.config[family][tbl][chain] = {}
	       end
	    else
	       io.stderr:write(
		  'Warning: not flushing unknown table: '..tbl..'\n'
	       )
	    end
	 end
      end
   end
   empty:restore(false)
end

return M