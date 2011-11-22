require 'fog/core/model'

module Fog
  module Compute
    class Vmfusion

      class Server < Fog::Model

        identity :name

        attribute :name
        # uuid.bios
        attribute :uuid
        # uuid.location
        attribute :instance_uuid
        attribute :operatingsystem
        attribute :ipaddress
        attribute :power_state
        attribute :mac_addresses
        attribute :path

        attr_accessor :password
        attr_writer   :private_key, :private_key_path, :public_key, :public_key_path, :username
        def initalize(attributes = {})
        end

        # There is currently no documented model of creating VMs from scratch
        # sans Fusion's wizard.
        def save
          raise Fog::Errors::Error.new('Creating a new vm is not yet supported')
        end

        # Fussion doesn't have the concept of templates so one just clones
        # regular VMs.
        def clone(name)
          requires :raw

          ::Fission::VM.clone(@raw.name,name)
          return connection.servers.get(name)
        end

        # Destroy, deletes the VM from the local disk but only hard stops the VM
        # before doing so if you set :force to true.
        def destroy(options = { :force => false })
          requires :raw

          if ready?
            if options[:force]
              stop
            end
          end

          ::Fission::VM.delete @raw.name
        end

        # Start is pretty self explanatory...if you pass :headless as true you
        # won't get a console on launch.
        def start(options = { :headless => false })
          requires :raw

          unless ready?
            @raw.start(:headless => options[:headless])
            return true
          else
            return false
          end
        end

        # Were covering a lot of bases here with the different ways one can stop
        # a VM from running.

        # Stop is a hard stop, like pulling out the power cord.
        def stop
          requires :raw

          if ready?
            @raw.stop(:hard => true)
            return true
          else
            return false
          end
        end

        # Halt and poweroff are just synonyms for stop.
        def halt
          stop
        end

        def poweroff
          stop
        end

        # This is a graceful shutdown but Fusion is only capable of a graceful
        # shutdown if tools are installed.  Fussion does the right thing though
        # and if graceful can't be initiated it just does likes a stop.
        def shutdown
          requires :raw
          if ready?
            @raw.stop
            return true
          else
            return false
          end
        end

        # Attempt a graceful shutdown, wait for the VM to completely shutdown
        # and then start it again.
        def reboot
          if ready?
            shutdown
            wait_for { ! ready? }
            start
            return true
          else
            return false
          end
        end

        # Resuming from suspend is the same thing as start to Fusion.
        def resume
          start
        end

        def suspend
          requires :raw
          if ready?
            @raw.suspend
            return true
          else
            return false
          end
        end

        # Fusion VM Metadata.

        # The power state of the VM is commonly going to be three values;
        # running, not running, or suspended.
        def power_state
          requires :raw
          @raw.state.data
        end

        def ready?
          requires :raw
          @raw.running?.data
        end

        # Path to the VM's vmx file on the local disk.
        def path
          requires :raw
          @raw.path
        end

        # We obtain the first ipaddress.  This should generally be a safe
        # assumption for Fusion.  Even if an address is provided via NAT,
        # bridge, or host only it will by accessible from the host machine the
        # VM resides on.
        def ipaddress
          requires :raw
          @raw.network_info.data['ethernet0']['ip_address']
        end

        # Keeping these three methods around for API compatibility reasons.
        # Makes the vmfusion provider function similar to cloud providers and
        # the vsphere provider.
        def public_ip_address(:public)
          ipaddress
        end

        def private_ip_address(:private)
          ipaddress
        end

        def state
          power_state
        end

        # Collecting all mac_addresses the VM has...mostly just because we are
        # doing the same thing for the vSphere provider.
        def mac_addresses
          requires :raw
          macs = @raw.mac_addresses.data
        end

        # Sets up a conveinent way to SSH into a Fusion VM using credentials
        # stored in you .fog file.

        def username
          @username ||= 'root'
        end

        # Simply spawn an SSH session.
        def ssh(commands)
          requires :ipaddress, :username

          #requires :password, :private_key
          ssh_options={}
          ssh_options[:password] = password unless password.nil?
          ssh_options[:key_data] = [private_key] if private_key

          Fog::SSH.new(ipaddress, @username, ssh_options).run(commands)

        end

        # SCP something to our VM.
        def scp(local_path, remote_path, upload_options = {})
          requires :ipaddress, :username

          scp_options = {}
          scp_options[:password] = password unless self.password.nil?
          scp_options[:key_data] = [private_key] if self.private_key

          Fog::SCP.new(ipaddress, username, scp_options).upload(local_path, remote_path, upload_options)
        end

        # Sets up a new SSH key on the VM so one doesn't need to use a password
        # ever again.
        def setup(credentials = {})
          requires :public_key, :ipaddress, :username

          credentials[:password] = password unless self.password.nil?
          credentails[:key_data] = [private_key] if self.private_key

          commands = [
            %{mkdir .ssh},
          ]
          if public_key
            commands << %{echo "#{public_key}" >> ~/.ssh/authorized_keys}
          end

          # wait for domain to be ready
          Timeout::timeout(360) do
            begin
              Timeout::timeout(8) do
                Fog::SSH.new(ipaddress, username, credentials.merge(:timeout => 4)).run('pwd')
              end
            rescue Errno::ECONNREFUSED
              sleep(2)
              retry
            rescue Net::SSH::AuthenticationFailed, Timeout::Error
              retry
            end
          end
          Fog::SSH.new(ipaddress, username, credentials).run(commands)
        end

        # Just setting local versions of some variables that were going to use
        # for SSH operations.
        def private_key_path
          @private_key_path ||= Fog.credentials[:private_key_path]
          @private_key_path &&= File.expand_path(@private_key_path)
        end

        def private_key
          @private_key ||= private_key_path && File.read(private_key_path)
        end

        def public_key_path
          @public_key_path ||= Fog.credentials[:public_key_path]
          @public_key_path &&= File.expand_path(@public_key_path)
        end

        def public_key
          @public_key ||= public_key_path && File.read(public_key_path)
        end

        private
        def raw
          @raw
        end

        def raw=(new_raw)
          @raw = new_raw

          raw_attributes = {
            :name            => new_raw.name,
            :power_state     => new_raw.state.data,
            :ipaddress       => new_raw.network_info.data['ethernet0']['ip_address'],
            :operatingsystem => new_raw.guestos.data,
            :uuid            => new_raw.uuids.data['bios'],
            :instance_uuid   => new_raw.uuids.data['location']
          }

          merge_attributes(raw_attributes)
        end

      end
    end
  end
end
