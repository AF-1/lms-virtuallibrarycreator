#
# Virtual Library Creator
# (c) 2023 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::VirtualLibraryCreator::ConfigManager::VLWebPageMethods;

use strict;
use Plugins::VirtualLibraryCreator::ConfigManager::WebPageMethods;
our @ISA = qw(Plugins::VirtualLibraryCreator::ConfigManager::WebPageMethods);

use Slim::Utils::Strings qw(string);

sub new {
	my $class = shift;
	my $parameters = shift;

	my $self = $class->SUPER::new($parameters);
	return $self;
}

1;
