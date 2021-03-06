# Copyright (C) 2011-2013 Zentyal S.L.
#
# This program is free softwa re; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
use strict;
use warnings;

package EBox::IPsec;

use base qw(EBox::Module::Service
            EBox::NetworkObserver
            EBox::FirewallObserver
            EBox::LogObserver);

use EBox::Gettext;

use EBox::IPsec::FirewallHelper;
use EBox::IPsec::LogHelper;
use EBox::NetWrappers qw();

use File::Slurp;

use constant IPSECCONFFILE => '/etc/ipsec.conf';
use constant IPSECSECRETSFILE => '/etc/ipsec.secrets';
use constant CHAPSECRETSFILE => '/etc/ppp/chap-secrets';

# Constructor: _create
#
#      Create a new EBox::IPsec module object
#
# Returns:
#
#      <EBox::IPsec> - the recently created model
#
sub _create
{
    my $class = shift;

    my $self = $class->SUPER::_create(name => 'ipsec',
                                      printableName => 'IPsec',
                                      @_);

    bless($self, $class);

    return $self;
}

# Method: usedFiles
#
#       Override EBox::Module::Service::usedFiles
#
sub usedFiles
{
    my @conf_files = ();

    push (@conf_files, {
        'file' => IPSECCONFFILE,
        'module' => 'ipsec',
        'reason' => __('To configure OpenSwan IPsec.')
    });

    push (@conf_files, {
        'file' => IPSECSECRETSFILE,
        'module' => 'ipsec',
        'reason' => __('To configure OpenSwan IPsec passwords.')
    });

    push (@conf_files, {
        'file' => CHAPSECRETSFILE,
        'module' => 'ipsec',
        'reason' => __('To configure L2TP/IPSec users when not using Active Directory validation.')
    });

    return \@conf_files;

}

# Method: _daemons
#
# Overrides:
#
#      <EBox::Module::Service::_daemons>
#
sub _daemons
{
    return [
        {
            'name' => 'ipsec',
            'type' => 'init.d',
            'pidfiles' => ['/var/run/pluto/pluto.pid'],
        }
    ];
}

# Method: initialSetup
#
# Overrides:
#
#      <EBox::Module::Base::initialSetup>
#
sub initialSetup
{
    my ($self, $version) = @_;
    my $global = $self->global();

    unless ($version) {
        my $services = $global->modInstance('services');

        my $serviceName = 'IPsec';
        unless($services->serviceExists(name => $serviceName)) {
            $services->addMultipleService(
                'name' => $serviceName,
                'description' => __('IPsec based VPN'),
                'internal' => 1,
                'readOnly' => 1,
                'services' => $self->_services(),
            );
        }

        my $firewall = $global->modInstance('firewall');
        $firewall->setExternalService($serviceName, 'accept');

        $firewall->saveConfigRecursive();
    }
}

sub _services
{
    my @services = ();

    # Encapsulation header.
    push (@services, {
        'protocol' => 'esp',
        'sourcePort' => 'any',
        'destinationPort' => 'any',
        });

    # Internet Key Exchange
    push (@services, {
        'protocol' => 'udp',
        'sourcePort' => 'any',
        'destinationPort' => '500',
        });

    # NAT traversal
    push (@services, {
        'protocol' => 'udp',
        'sourcePort' => 'any',
        'destinationPort' => '4500',
        });

    return \@services;
}

# Method: _setConf
#
# Overrides:
#
#      <EBox::Module::Service::_setConf>
#
sub _setConf
{
    my ($self) = @_;

    $self->_setIPsecConf();
    $self->_setIPsecSecrets();
    $self->_setXL2TPDConf();
}

sub _setIPsecConf
{
    my ($self) = @_;

    my @params = ();

    push (@params, tunnels => $self->tunnels());

    $self->writeConfFile(IPSECCONFFILE, "ipsec/ipsec.conf.mas", \@params,
                            { 'uid' => 'root', 'gid' => 'root', mode => '600' });
}

sub _setIPsecSecrets
{
    my ($self) = @_;

    my @params = ();

    push (@params, tunnels => $self->tunnels());

    $self->writeConfFile(IPSECSECRETSFILE, "ipsec/ipsec.secrets.mas", \@params,
                            { 'uid' => 'root', 'gid' => 'root', mode => '600' });
}

sub _setXL2TPDUsers
{
    my ($self) = @_;

    my $model = $self->model('UsersFile');

    my $l2tpConf = '';
    foreach my $user (@{$model->getUsers()}) {
        $user->{ipaddr} = '*' unless $user->{ipaddr};
        $l2tpConf .= "$user->{user} l2tp $user->{passwd} $user->{ipaddr}\n";
    }
    my $file = read_file(CHAPSECRETSFILE);
    my $mark = '# L2TP_CONFIG - managed by Zentyal. Dont edit this section #';
    my $endMark = '# END of L2TP_CONFIG section #';
    if ($file =~ m/$mark/sm) {
        $file =~ s/$mark.*$endMark/$mark\n$l2tpConf$endMark/sm;
    } else {
        $file .= $mark . "\n" . $l2tpConf . $endMark . "\n";
    }

    write_file(CHAPSECRETSFILE, $file);
}

sub _setXL2TPDConf
{
    my ($self) = @_;
    my $global = $self->global();

    # Clean all upstart and configuration files, the current ones will be regenerated
    EBox::Sudo::silentRoot(
        "rm -rf /etc/init/zentyal-xl2tpd.*.conf",
        "rm -rf /etc/ppp/zentyal-options.xl2tpd.*",
        "rm -rf /etc/xl2tpd/zentyal-xl2tpd.*.conf"
    );

    my $workgroup = undef;
    my $users = $self->model('Users');
    my $validationGroup = $users->validationGroup();

    if ($validationGroup) {
        my $samba = $global->modInstance('samba');
        $workgroup = $samba->workgroup();
    } else {
        $self->_setXL2TPDUsers();
    }

    my $permissions = {
        uid => 'root',
        gid => 'root',
        mode => '644',
    };

    foreach my $tunnel (@{ $self->tunnels() }) {
        my @params = ();
        if ($tunnel->{'type'} eq 'l2tp') {
            if ($validationGroup) {
                push (@params, group => "$workgroup\\\\$validationGroup");
                push (@params, chap => 0);
            } else {
                push (@params, group => undef);
                push (@params, chap => 1);
            }
            push (@params, tunnel => $tunnel);

            $self->writeConfFile(
                "/etc/xl2tpd/zentyal-xl2tpd.$tunnel->{name}.conf", "ipsec/xl2tpd.conf.mas", \@params, $permissions);
            $self->writeConfFile(
                "/etc/ppp/zentyal-options.xl2tpd.$tunnel->{name}", "ipsec/options.xl2tpd.mas", \@params, $permissions);
            $self->writeConfFile(
                "/etc/init/zentyal-xl2tpd.$tunnel->{name}.conf", "ipsec/upstart-xl2tpd.mas", \@params, $permissions);
        }
    }
}

sub tunnels
{
    my ($self) = @_;

    my $vpn = $self->model('Connections');

    return $vpn->tunnels();
}

sub firewallHelper
{
    my ($self) = @_;

    my $enabled = $self->isEnabled();

    my @activeTunnels = @{$self->tunnels()};
    my @networksNoToMasquerade = ();
    my $hasL2TP = undef;
    my @L2TPInterfaces = ();
    foreach my $tunnel (@activeTunnels) {
        if ($tunnel->{type} eq 'l2tp') {
            $hasL2TP = 1;
            my $interface = EBox::NetWrappers::iface_by_address($tunnel->{local_ip});
            if ($interface) {
                push (@L2TPInterfaces, $interface);
            }
        }
        my $subnet = $tunnel->{'right_subnet'};
        next unless $subnet;
        push(@networksNoToMasquerade, $subnet);
    }

    my $firewallHelper = new EBox::IPsec::FirewallHelper(
        service => $enabled,
        networksNoToMasquerade => \@networksNoToMasquerade,
        hasL2TP => $hasL2TP,
        L2TPInterfaces => \@L2TPInterfaces,
    );

    return $firewallHelper;
}

# Method: logHelper
#
# Overrides:
#
#       <EBox::LogObserver::logHelper>
#
sub logHelper
{
    my ($self, @params) = @_;
    return EBox::IPsec::LogHelper->new($self, @params);
}

# Method: tableInfo
#
# Overrides:
#
#       <EBox::LogObserver::tableInfo>
#
sub tableInfo
{
    my ($self) = @_;
    my $titles = {
                  timestamp => __('Date'),
                  event     => __('Event'),
                  tunnel    => __('Connection name'),
                 };
    my @order = qw(timestamp event tunnel);

    my $events = {
                  initialized   => __('Initialization sequence completed'),
                  stopped       => __('Stopping completed'),

                  connectionInitiated   => __('Connection initiated'),
                  connectionReset       => __('Connection terminated'),
                 };

    return [{
            'name'      => $self->printableName(),
            'tablename' => 'ipsec',
            'titles'    => $titles,
            'order'     => \@order,
            'timecol'   => 'timestamp',
            'filter'    => ['tunnel'],
            'events'    => $events,
            'eventcol'  => 'event'
           }];
}

# Method: menu
#
#       Overrides <EBox::Module::menu> method.
#
sub menu
{
    my ($self, $root) = @_;

    my $folder = new EBox::Menu::Folder(
                                        'icon' => 'openvpn',
                                        'name' => 'VPN',
                                        'text' => 'VPN',
                                        'separator' => 'Infrastructure',
                                        'order' => 330
                                       );

    $folder->add(
                 new EBox::Menu::Item(
                                      'url' => 'VPN/IPsec',
                                      'text' => __('IPsec'),
                                      'order' => 30
                                     )
    );

    $root->add($folder);
}

1;
