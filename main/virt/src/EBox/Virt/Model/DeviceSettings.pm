# Copyright (C) 2011 eBox Technologies S.L.
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


package EBox::Virt::Model::DeviceSettings;

# Class: EBox::Virt::Model::DeviceSettings
#
#      Table with the network interfaces of the Virtual Machine
#

use base 'EBox::Model::DataTable';

use strict;
use warnings;

use EBox::Global;
use EBox::Gettext;
use EBox::Types::Text;
use EBox::Types::Select;

# Group: Public methods

# Constructor: new
#
#       Create the new DeviceSettings model.
#
# Overrides:
#
#       <EBox::Model::DataForm::new>
#
# Returns:
#
#       <EBox::Virt::Model::DeviceSettings> - the recently created model.
#
sub new
{
    my $class = shift;

    my $self = $class->SUPER::new(@_);

    bless ($self, $class);

    return $self;
}

# Group: Private methods


sub _populateDriveTypes
{
    return [
            { value => 'hd', printableValue => __('Hard Disk') },
            { value => 'cd', printableValue => 'CD/DVD' },
    ];
}

# Method: _table
#
# Overrides:
#
#      <EBox::Model::DataTable::_table>
#
sub _table
{
    my @tableHeader = (
       new EBox::Types::Select(
                               fieldName     => 'type',
                               printableName => __('Type'),
                               populate      => \&_populateDriveTypes,
                               editable      => 1,
                              ),
       new EBox::Types::Text(
                             fieldName     => 'path',
                             printableName => __('Path'),
                             editable      => 1,
                            ),
       # TODO: This only makes sense for HDs, hide it with
       # viewCustomizer if CD is selected
       new EBox::Types::Int(
                            fieldName     => 'size',
                            printableName => __('Size'),
                            editable      => 1,
                            defaultValue  => 8000,
                            min           => 32,
                            max           => 100000, # TODO: Get free space or remove this limit?
                            trailingText  => 'MB',
                           ),
    );

    my $dataTable =
    {
        tableName          => 'DeviceSettings',
        printableTableName => __('Device Settings'),
        printableRowName   => __('drive'),
        defaultActions     => [ 'add', 'del', 'editField', 'changeView' ],
        tableDescription   => \@tableHeader,
        order              => 1,
        enableProperty     => 1,
        class              => 'dataTable',
        help               => __('Here you can define the storage drives of the virtual machine'),
        modelDomain        => 'Virt',
    };

    return $dataTable;
}

# FIXME: Workaround for the composite-children-of-submodel bug
sub parentRow
{
    my ($self) = @_;

    my $parent = $self->parent();
    return $parent ? $parent->parentRow() : undef;
}

1;