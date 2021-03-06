# Copyright (C) 2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
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

package EBox::Users::Model::Manage;

use base 'EBox::Model::TreeView';

use EBox::Gettext;
use EBox::Users;
use EBox::Types::Action;

use Error qw(:try);

sub _tree
{
    my ($self) = @_;

    return {
        treeName => 'Manage',
        modelDomain => 'Users',
        pageTitle => $self->parentModule()->printableName(),
        defaultActions => [ 'add', 'delete' ],
        help =>  __('Here you can manage Organizational Units, Users, Groups and Contacts. Also you can see the computers in the domain if using Samba. Please note that multiple OU support is partial, some modules may only work with users and groups in the default Users and Groups OUs.'),
    };
}

sub rootNodes
{
    my ($self) = @_;

    my $usersMod = $self->parentModule();
    my $defaultNamingContext = $usersMod->defaultNamingContext();

    return [ { id => 'root', printableName => $defaultNamingContext->baseName(), type => 'domain', metadata => { dn => $defaultNamingContext->dn() } } ];
}

sub childNodes
{
    my ($self, $parentType, $parentMetadata) = @_;

    my $usersMod = $self->parentModule();

    my $samba = EBox::Global->modInstance('samba');

    my $parentObject = undef;
    if ($parentType eq 'domain') {
        $parentObject = $usersMod->defaultNamingContext();
    } elsif ($parentType eq 'computer') {
        # dont look for childs in computers
        return [];
    } elsif (($parentMetadata->{dn} =~ /^ou=Computers,/i) and defined ($samba)) {
        # FIXME: Integrate this better with the rest of the logic.
        return $self->_sambaComputers();
    } else {
        $parentObject = $usersMod->objectFromDN($parentMetadata->{dn});
    }

    my $printableName = undef;
    my $type = undef;
    my @childNodes = ();
    foreach my $child (@{$parentObject->children()}) {
        next if (defined ($samba) and $samba->hiddenViewInAdvancedOnly($child));

        my $dn = $child->dn();
        if ($child->isa('EBox::Users::OU')) {
            $type = 'ou';
            $printableName = $child->name();
            next if ($self->_hiddenOU($child->canonicalName(1)));
        } elsif ($child->isa('EBox::Users::User')) {
            next if (defined ($samba) and $samba->hiddenSid($child));

            if ($child->isDisabled()) {
                $type = 'duser';
            } else {
                $type = 'user';
            }
            $printableName = $child->name();

            # FIXME: temporary workaround until the regression is fixed properly
            use Sys::Hostname;
            my $hostname = Sys::Hostname::hostname();
            next if ($printableName =~ /^(\w+)-$hostname$/);

            my $fullname = $child->fullname();
            if ($fullname) {
                $printableName .= " ($fullname)";
            }
        } elsif ($child->isa('EBox::Users::Contact')) {
            $type = 'contact';
            $printableName = $child->fullname();
        } elsif ($child->isa('EBox::Users::Group')) {
            next if ($child->name() eq EBox::Users::DEFAULTGROUP());
            next if (defined ($samba) and $samba->hiddenSid($child));

            $type = $child->isSecurityGroup() ? 'group' : 'dgroup';
            $printableName = $child->name();
        } elsif ($child->isa('EBox::Users::Container::ExternalAD')) {
            #^ container class only used in ExternalAD mode
            # for now we are only interested in the user containers
            $child->usersContainer() or
                next;
            $type = 'container';
            $printableName = $child->name();
        } else {
            EBox::warn("Unknown object type for DN: " . $child->dn());
            next;
        }
        push (@childNodes, { id => $dn, printableName => $printableName, type => $type, metadata => { dn => $dn } });
    }

    return \@childNodes;
}

sub _sambaComputers
{
    my ($self) = @_;

    my $samba = EBox::Global->modInstance('samba');

    my @computers;

    foreach my $computer (@{$samba->computers()}) {
        my $dn = $computer->dn();
        my $printableName = $computer->name();
        push (@computers, { id => $dn, printableName => $printableName, type => 'computer', metadata => { dn => $dn } });
    }

    return \@computers;
}

sub nodeTypes
{
    my ($self) = @_;
    my $usersMod = $self->parentModule();
    my $rw = $usersMod->mode() eq $usersMod->STANDALONE_MODE;

    return {
        domain => { actions => { filter => 0, add => $rw }, actionObjects => { add => 'OU' } },
        ou => { actions => { filter => 0, add => $rw, delete => $rw }, actionObjects => { delete => 'OU', add => 'Object' }, defaultIcon => 1 },
        container => { actions => { filter => 0, add => $rw, delete => $rw }, actionObjects => { delete => 'OU', add => 'Object' }, defaultIcon => 1 },
        user => { printableName => __('Users'), actions => { filter => 1, edit => $rw, delete => $rw } },
        duser => { printableName => __('Disabled Users'), actions => { filter => 1, edit => $rw, delete => $rw },
                                                          actionObjects => { edit => 'User', delete => 'User' } },
        group => { printableName => __('Security Groups'), actions => { filter => 1, edit => $rw, delete => $rw } },
        dgroup => { printableName => __('Distribution Groups'), actions => { filter => 1, edit => $rw, delete => $rw },
                                                                actionObjects => { edit => 'Group', delete => 'Group' } },
        computer => { printableName => __('Computers'), actions => { filter => 1 } },
        contact => { printableName => __('Contacts'), actions => { filter => 1, edit => $rw, delete => $rw } },
    };
}

# Method: precondition
#
# Check if the module is configured
#
# Overrides:
#
# <EBox::Model::Base::precondition>
#
sub precondition
{
    my ($self) = @_;

    return $self->parentModule()->configured();
}

# Method: preconditionFailMsg
#
# Check if the module is configured
#
# Overrides:
#
# <EBox::Model::Model::preconditionFailMsg>
#
sub preconditionFailMsg
{
    my ($self) = @_;

    return __('You must enable the module Users in the module status section in order to use it.');
}

sub _hiddenOU
{
    my ($self, $name) = @_;

    unless ($self->{ousToHide}) {
        $self->{ousToHide} = { map { $_ => 1 } @{$self->parentModule()->ousToHide()} };
    }

    return $self->{ousToHide}->{$name};
}

1;
