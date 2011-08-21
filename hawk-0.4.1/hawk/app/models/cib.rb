#======================================================================
#                        HA Web Konsole (Hawk)
# --------------------------------------------------------------------
#            A web-based GUI for managing and monitoring the
#          Pacemaker High-Availability cluster resource manager
#
# Copyright (c) 2009-2011 Novell Inc., Tim Serong <tserong@novell.com>
#                        All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it would be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# Further, this software is distributed without any warranty that it is
# free of the rightful claim of any third person regarding infringement
# or the like.  Any license provided herein, whether implied or
# otherwise, applies only to this software file.  Patent licenses, if
# any, provided herein do not apply to combinations of this program with
# other software, or any other product whatsoever.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write the Free Software Foundation,
# Inc., 59 Temple Place - Suite 330, Boston MA 02111-1307, USA.
#
#======================================================================

require 'util'
require 'natcmp'
require 'rexml/document' unless defined? REXML::Document

class Cib < CibObject
  include GetText

  protected

  # Roughly equivalent to crm_element_value() in Pacemaker
  def get_xml_attr(elem, name, default = nil)
    Util.unstring(elem.attributes[name], default)
  end

  def get_property(property, default = nil)
    # TODO(could): theoretically this xpath is a bit loose.
    e = @xml.elements["//nvpair[@name='#{property}']"]
    e ? get_xml_attr(e, 'value', default) : default
  end

  def get_resource(elem, clone_max = nil, is_ms = false)
    res = {
      :id => elem.attributes['id']
    }
    @resources_by_id[elem.attributes['id']] = res
    case elem.name
    when 'primitive'
      res[:class]     = elem.attributes['class']
      res[:provider]  = elem.attributes['provider'] # This will be nil for LSB resources
      res[:type]      = elem.attributes['type']
      res[:instances] = {}
      # This is a bit of a hack to ensure we have a complete set of instances later
      res[:clone_max] = clone_max if clone_max
      # Likewise to s/started/slave/
      res[:is_ms]     = is_ms
    when 'group', 'clone', 'master'
      # For non-primitives we overload :type (it's not a primitive if
      # it has children, or, for that matter, if it has no class)
      res[:type]     = elem.name
      res[:children] = []
      if elem.name == 'clone' || elem.name == 'master'
        nvpair = elem.elements["meta_attributes/nvpair[@name='clone-max']"]
        clone_max = nvpair ? nvpair.attributes['value'].to_i : @nodes.length
      end
      if elem.elements['primitive']
        elem.elements.each('primitive') do |p|
          res[:children] << get_resource(p, clone_max, is_ms || elem.name == 'master')
        end
      elsif elem.elements['group']
        res[:children] << get_resource(elem.elements['group'], clone_max, is_ms || elem.name == 'master')
      else
        # This can't happen
        RAILS_DEFAULT_LOGGER.error "Got #{elem.name} without 'primitive' or 'group' child"
      end
    else
      # This can't happen
        RAILS_DEFAULT_LOGGER.error "Unknown resource type: #{elem.name}"
    end
    res
  end

  # Hack to:
  # - inject additional instances for clones if there's no LRM state for them
  # - remove default instance for clones (shouldn't be there, but will be due
  #   to orphans if you create a clone from a running primitive or group).
  # - remove clone instances from primitives (shouldn't be there, but will be
  #   due to orphans if you un-clone a running cloned primitive or group)
  def fix_clone_instances(resources)
    for res in resources
      if res[:clone_max]
        instance = 0
        while res[:instances].length < res[:clone_max]
          while res[:instances].has_key?(instance.to_s)
            instance += 1
          end
          res[:instances][instance.to_s] = {}
        end
        res[:instances].delete(:default) if res[:instances].has_key?(:default)
        res.delete :clone_max
      else
        res[:instances].delete_if {|k, v| k != :default} if res.has_key?(:instances)
      end
      fix_clone_instances(res[:children]) if res[:children]
    end
  end

  # transliteration of pacemaker/lib/pengine/unpack.c:determine_online_status_fencing()
  # ns is node_state element from CIB
  def determine_online_status_fencing(ns)
    ha_state    = get_xml_attr(ns, 'ha', 'dead')
    in_ccm      = get_xml_attr(ns, 'in_ccm')
    crm_state   = get_xml_attr(ns, 'crmd')
    join_state  = get_xml_attr(ns, 'join')
    exp_state   = get_xml_attr(ns, 'expected')

    # expect it to be up (more or less) if 'shutdown' is '0' or unspecified
    expected_up = get_xml_attr(ns, 'shutdown', '0') == 0

    state = :unclean
    if in_ccm && ha_state == 'active' && crm_state == 'online'
      case join_state
      when 'member'         # rock 'n' roll (online)
        state = :online
      when exp_state        # coming up (!online)
        state = :offline
      when 'pending'        # technically online, but not ready to run resources
        state = :pending    # (online + pending + standby)
      when 'banned'         # not allowed to be part of the cluster
        state = :standby    # (online + pending + standby)
      else                  # unexpectedly down (unclean)
        state = :unclean
      end
    elsif !in_ccm && ha_state =='dead' && crm_state == 'offline' && !expected_up
      state = :offline      # not online, but cleanly
    elsif expected_up
      state = :unclean      # expected to be up, mark it unclean
    else
      state = :offline      # offline
    end
    return state
  end

  # transliteration of pacemaker/lib/pengine/unpack.c:determine_online_status_no_fencing()
  # ns is node_state element from CIB
  # TODO(could): can we consolidate this with determine_online_status_fencing?
  def determine_online_status_no_fencing(ns)
    ha_state    = get_xml_attr(ns, 'ha', 'dead')
    in_ccm      = get_xml_attr(ns, 'in_ccm')
    crm_state   = get_xml_attr(ns, 'crmd')
    join_state  = get_xml_attr(ns, 'join')
    exp_state   = get_xml_attr(ns, 'expected')

    # expect it to be up (more or less) if 'shutdown' is '0' or unspecified
    expected_up = get_xml_attr(ns, 'shutdown', '0') == 0

    state = :unclean
    if !in_ccm || ha_state == 'dead'
      state = :offline
    elsif crm_state == 'online'
      if join_state == 'member'
        state = :online
      else
        # not ready yet (should this break down to pending/banned like
        # determine_online_status_fencing?  It doesn't in unpack.c...)
        state = :offline
      end
    elsif !expected_up
      state = :offline
    else
      state = :unclean
    end
    return state
  end

  public

  # Notes that errors here overloads what ActiveRecord would
  # use for reporting errors when editing resources.  This
  # should almost certainly be changed.
  attr_reader :dc, :epoch, :nodes, :resources, :crm_config, :errors

  def initialize(id, user, use_file = false)
    @errors = []

    if use_file
      cib_path = id
      # TODO(must): This is a bit rough
      cib_path.gsub! /[^\w-]/, ''
      cib_path = "#{RAILS_ROOT}/test/cib/#{cib_path}.xml"
      raise ArgumentError, _('CIB file "%{path}" not found') % {:path => cib_path } unless File.exist?(cib_path)
      @xml = REXML::Document.new(File.new(cib_path))
      raise RuntimeError, _('Unable to parse CIB file "%{path}"') % {:path => cib_path } unless @xml.root
    elsif id == 'live'
      raise RuntimeError, _('Pacemaker does not appear to be installed (%{cmd} not found)') %
                             {:cmd => '/usr/sbin/crm_mon' } unless File.exists?('/usr/sbin/crm_mon')
      raise RuntimeError, _('Unable to execute %{cmd}') % {:cmd => '/usr/sbin/crm_mon' } unless File.executable?('/usr/sbin/crm_mon')
      crm_status = %x[/usr/sbin/crm_mon -s 2>&1].chomp
      # TODO(should): this is dubious (WAR: crm_mon -s giving "status: 1, output was: Warning:offline node: hex-14")
      raise RuntimeError, _('%{cmd} failed (status: %{status}, output was: %{output})') %
                        {:cmd    => '/usr/sbin/crm_mon',
                         :status => $?.exitstatus,
                         :output => crm_status } if $?.exitstatus == 10 || $?.exitstatus == 11
      stdin, stdout, stderr, thread = Util.run_as(user, 'cibadmin', '-Ql')
      stdin.close
      out = stdout.read()
      stdout.close
      err = stderr.read()
      stderr.close
      case thread.value.exitstatus
      when 0
        @xml = REXML::Document.new(out)
        raise RuntimeError, _('Error invoking %{cmd}') % {:cmd => '/usr/sbin/cibadmin -Ql' } unless @xml.root
      when 54
        # 54 is cib_permission_denied
        raise SecurityError, _('Permission denied for user %{user}') % {:user => user}
      else
        raise RuntimeError, _('Error invoking %{cmd}: %{msg}') % {:cmd => '/usr/sbin/cibadmin -Ql', :msg => err }
      end
    else
      # Only provide the live CIB and static test files (no shadow functionality yet)
      raise ArgumentError, _('Only the live CIB is supported')
    end

    @id = id

    # Special-case defaults for properties we always want to see
    @crm_config = {
      :"cluster-infrastructure"       => _('Unknown'),
      :"dc-version"                   => _('Unknown'),
      :"default-resource-stickiness"  => 0, # TODO(could): is this documented?
      :"stonith-enabled"              => true,
      :"symmetric-cluster"            => true,
      :"no-quorum-policy"             => 'stop'
    }

    # Pull in everything else
    # TODO(should): This gloms together all cluster property sets; really
    # probably only want cib-bootstrap-options?
    @xml.elements.each('cib/configuration/crm_config//nvpair') do |p|
      @crm_config[p.attributes['name'].to_sym] = get_xml_attr(p, 'value')
    end

    @nodes = []
    @xml.elements.each('cib/configuration/nodes/node') do |n|
      uname = n.attributes['uname']
      state = :unclean
      ns = @xml.elements["cib/status/node_state[@uname='#{uname}']"]
      if ns
        state = crm_config[:stonith_enabled] ? determine_online_status_fencing(ns) : determine_online_status_no_fencing(ns)
        if state == :online
          standby = n.elements["instance_attributes/nvpair[@name='standby']"]
          # TODO(could): is the below actually a sane test?
          if standby && ['true', 'yes', '1', 'on'].include?(standby.attributes['value'])
            state = :standby
          end
        end
      end
      @nodes << {
        :uname => uname,
        :state => state
      }
    end
    @nodes.sort!{|a,b| a[:uname].natcmp(b[:uname], true)}

    @resources = []
    @resources_by_id = {}
    @xml.elements.each('cib/configuration/resources/*') do |r|
      @resources << get_resource(r)
    end

    for node in @nodes
      next unless node[:state] == :online
      @xml.elements.each("cib/status/node_state[@uname='#{node[:uname]}']/lrm/lrm_resources/lrm_resource") do |lrm_resource|
        id = lrm_resource.attributes['id']
        # logic derived somewhat from pacemaker/lib/pengine/unpack.c:unpack_rsc_op()
        state = :unknown
        ops = []
        lrm_resource.elements.each('lrm_rsc_op') do |op|
          ops << op
        end
        ops.sort{|a,b|
          if a.attributes['call-id'].to_i != -1 && b.attributes['call-id'].to_i != -1
            # Normal case, neither op is pending, call-id wins
            a.attributes['call-id'].to_i <=> b.attributes['call-id'].to_i
          elsif a.attributes['operation'].starts_with?('migrate_') || b.attributes['operation'].starts_with?('migrate_')
            # Special case for pending migrate ops, beacuse stale ops hang around
            # in the CIB (see lf#2481).  There's a couple of things to do here:
            a_key = a.attributes['transition-key'].split(':')
            b_key = b.attributes['transition-key'].split(':')
            if a.attributes['transition-key'] == b.attributes['transition-key']
              # 1) if the transition keys match, newer call-id wins (ensures bogus
              # pending ops lose to immediately subsequent start/stop).
              a.attributes['call-id'].to_i <=> b.attributes['call-id'].to_i
            elsif a_key[3] == b_key[3]
              # 2) if the transition keys don't match but the transitioner UUIDs
              # *do* match, the migrate is either old (predating a start/stop that
              # occurred after a migrate's regular start/stop), or new (the current
              # pending op), in which case we assume the larger graph number is the
              # most recent op (this will break if uint64_t ever wraps).
              a_key[1].to_i <=> b_key[1].to_i
            else
              # If the transitioner UUIDs *don't* match (different instances
              # of crmd), we make the pending op most recent (reverse sort
              # call id), because experiment seems to indicate this is the
              # least-worst choice.  Pending migrate ops for a node evaporate
              # if Pacemaker is stopped on that node, so after a UUID change,
              # there should be at most one outstanding pending migrate op
              # that doesn't hit one of the other rules above - if this is
              # the case, this pending migrate op is what's happening right
              # *now*
              b.attributes['call-id'].to_i <=> a.attributes['call-id'].to_i
            end
          elsif a.attributes['call-id'].to_i == -1
            1                                         # make pending start/stop op most recent
          elsif b.attributes['call-id'].to_i == -1
            -1                                        # likewise
          else
            RAILS_DEFAULT_LOGGER.error "Inexplicable op sort error (this can't happen)"
            a.attributes['call-id'].to_i <=> b.attributes['call-id'].to_i
          end
        }.each do |op|
          operation = op.attributes['operation']
          rc_code = op.attributes['rc-code'].to_i
          expected = op.attributes['transition-key'].split(':')[2].to_i

          is_probe = operation == 'monitor' && op.attributes['interval'].to_i == 0

          # skip notifies
          next if operation == 'notify'

          if op.attributes['call-id'].to_i == -1
            state = :pending
            next
          end

          # TODO(should): evil magic numbers!
          case rc_code
          when 7
            # not running on this node
            state = :stopped
          when 8
            # master on this node
            state = :master
          when 0
            # ok
            if operation == 'stop' || operation == 'migrate_to'
              state = :stopped
            elsif operation == 'promote'
              state = :master
            else
              # anything other than a stop means we're running (although might be
              # slave after a demote)
              # TODO(must): verify this demote business
              state = :started
            end
          end
          if !is_probe && rc_code != expected
            # busted somehow
            @errors << _('Failed op: node=%{node}, resource=%{resource}, call-id=%{call_id}, operation=%{op}, rc-code=%{rc_code}') %
              { :node => node[:uname], :resource => id, :call_id => op.attributes['call-id'], :op => operation, :rc_code => rc_code }
          end
        end

        # TODO(should): want some sort of assert "status != :unknown" here

        # Now we've got the status on this node, let's stash it away
        (id, instance) = id.split(':')
        if @resources_by_id[id]
          # m/s slave state hack (*sigh*)
          state = :slave if @resources_by_id[id][:is_ms] && state == :started
          # instance will be nil here for regular primitives
          instance = :default unless instance
          @resources_by_id[id][:instances][instance] = {} unless @resources_by_id[id][:instances][instance]
          @resources_by_id[id][:instances][instance][state] = [] unless @resources_by_id[id][:instances][instance][state]
          @resources_by_id[id][:instances][instance][state] << node[:uname]
        else
          # It's an orphan
          # TODO(should): display this somewhere? (at least log it during testing)
        end
      end
    end

    fix_clone_instances @resources

    # More hack
    @resources_by_id.each do |k,v|
      @resources_by_id[k].delete :is_ms
      # Need to inject a default instance if we don't have any state
      # (e.g. during cluster bringup) else the panel renderer chokes.
      @resources_by_id[k][:instances][:default] = {} if @resources_by_id[k][:instances] && @resources_by_id[k][:instances].empty?
    end

    # TODO(should): Can we just use cib attribute dc-uuid?  Or is that not viable
    # during cluster bringup, given we're using cibadmin -l?
    # Note that crmadmin will wait a long time if the cluster isn't up yet - cap it at 100ms
    @dc = %x[/usr/sbin/crmadmin -t 100 -D 2>/dev/null].strip
    s = @dc.rindex(' ')
    @dc.slice!(0, s + 1) if s
    @dc = _('Unknown') if @dc.empty?
    
    @epoch = "#{get_xml_attr(@xml.root, 'admin_epoch')}:#{get_xml_attr(@xml.root, 'epoch')}:#{get_xml_attr(@xml.root, 'num_updates')}";
    
  end

  # If we were using ActiveRecord, we'd be able to use has_many etc. and
  # magically have cib.crm_configs.find.  But we're not, so we have this
  # thing instead.  Note that there is no particular error checking here;
  # if you ask for a crm_config that doesn't exist, you'll get back an
  # empty CrmConfig model.
  def find_crm_config(id)
    CrmConfig.new(@xml.elements['cib/configuration/crm_config'], id)
  end

end
