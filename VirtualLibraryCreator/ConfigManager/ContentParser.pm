#
# Virtual Library Creator
#
# (c) 2023 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::VirtualLibraryCreator::ConfigManager::ContentParser;

use strict;
use warnings;
use utf8;

use base qw(Slim::Utils::Accessor);
use Slim::Buttons::Home;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use File::Spec::Functions qw(:ALL);
use HTML::Entities;
use Data::Dumper;

use Plugins::VirtualLibraryCreator::ConfigManager::BaseParser;
our @ISA = qw(Plugins::VirtualLibraryCreator::ConfigManager::BaseParser);

my $log = logger('plugin.virtuallibrarycreator');
my $prefs = preferences('plugin.virtuallibrarycreator');

sub new {
	my ($class, $parameters) = @_;

	$parameters->{'contentType'} = 'virtuallibrary';
	my $self = $class->SUPER::new($parameters);
	return $self;
}

sub parse {
	my ($self, $client, $item, $content, $items, $globalcontext, $localcontext) = @_;
	return $self->parseContent($client, $item, $content, $items, $globalcontext, $localcontext);
}

sub parseContentImplementation {
	my ($self, $client, $item, $content, $items, $globalcontext, $localcontext) = @_;

	my $errorMsg = undef;
	if ($content) {
		decode_entities($content);

		my @virtualLibraryDataArray = split(/[\n\r]+/, $content);
		my $name = undef;
		my $statement = '';
		my $fulltext = '';
		my $isEnabled = 0;
		my $dailyVLrefresh = 0;
		my $libraryInitOrder = 0;
		my $external = externalCheck($item);
		my $browseMenusArtists = '';
		my $browseMenusArtistsHomeMenu = undef;
		my $browseMenusArtistsHomeMenuWeight = 0;
		my $browseMenusAlbums = '';
		my $browseMenusAlbumsHomeMenu = undef;
		my $browseMenusAlbumsHomeMenuWeight = 0;
		my $browseMenusMisc = '';
		my $browseMenusMiscHomeMenu = undef;
		my $browseMenusMiscHomeMenuWeight = 0;
		my $includedVLids = '';
		my $excludedVLids = '';

		for my $line (@virtualLibraryDataArray) {
			# Add linefeed to make sure virtualLibrary looks ok when editing
			$line .= "\n";
			if ($line !~ /^--/ && $line !~ /^\s*$/ && $line !~ /^\s*$/) {
				$fulltext .= $line if $external
			}
			chomp $line;

			# parse params & options
			my $vlNameString = parseVLname($line);
			if ($vlNameString) {
				$name = $vlNameString;
			}

			my $enabledVal = parseEnabled($line);
			if ($enabledVal) {
				$isEnabled = $enabledVal;
			}

			my $dailyVLrefreshVal = parseDailyRefresh($line);
			if ($dailyVLrefreshVal) {
				$dailyVLrefresh = $dailyVLrefreshVal;
			}

			my $libraryInitOrderVal = parseLibraryInitOrder($line);
			if ($libraryInitOrderVal) {
				$libraryInitOrder = $libraryInitOrderVal;
			}

			my $artistBrowseMenusString = parseArtistBrowseMenus($line);
			if ($artistBrowseMenusString) {
				$browseMenusArtists = $artistBrowseMenusString;
			}
			my $artistMenusHomeMenuEnabled = parseArtistMenusHomeMenuEnabled($line);
			if ($artistMenusHomeMenuEnabled) {
				$browseMenusArtistsHomeMenu = 1;
			}
			my $artistMenusHomeMenuWeight = parseArtistMenusHomeMenuWeight($line);
			if ($artistMenusHomeMenuWeight) {
				$browseMenusArtistsHomeMenuWeight = $artistMenusHomeMenuWeight;
			}

			my $albumBrowseMenusString = parseAlbumBrowseMenus($line);
			if ($albumBrowseMenusString) {
				$browseMenusAlbums = $albumBrowseMenusString;
			}
			my $albumMenusHomeMenuEnabled = parseAlbumMenusHomeMenuEnabled($line);
			if ($albumMenusHomeMenuEnabled) {
				$browseMenusAlbumsHomeMenu = 1;
			}
			my $albumMenusHomeMenuWeight = parseAlbumMenusHomeMenuWeight($line);
			if ($albumMenusHomeMenuWeight) {
				$browseMenusAlbumsHomeMenuWeight = $albumMenusHomeMenuWeight;
			}

			my $otherBrowseMenusString = parseOtherBrowseMenus($line);
			if ($otherBrowseMenusString) {
				$browseMenusMisc = $otherBrowseMenusString;
			}
			my $otherMenusHomeMenuEnabled = parseOtherMenusHomeMenuEnabled($line);
			if ($otherMenusHomeMenuEnabled) {
				$browseMenusMiscHomeMenu = 1;
			}
			my $otherMenusHomeMenuWeight = parseOtherMenusHomeMenuWeight($line);
			if ($otherMenusHomeMenuWeight) {
				$browseMenusMiscHomeMenuWeight = $otherMenusHomeMenuWeight;
			}

			my $includedVLidString = parseIncludedVLidString($line);
			if ($includedVLidString) {
				$includedVLids = $includedVLidString;
			}

			my $excludedVLidString = parseExcludedVLidString($line);
			if ($excludedVLidString) {
				$excludedVLids = $excludedVLidString;
			}

			# skip and strip comments & empty lines
			$line =~ s/\s*--.*?$//o;
			$line =~ s/^\s*//o;

			next if $line =~ /^--/;
			next if $line =~ /^\s*$/;

			$line =~ s/\s+$//;
			if ($statement) {
				if ($statement =~ /;$/) {
					$statement .= "\n";
				} else {
					$statement .= " ";
				}
			}
			$statement .= $line;
		}

		$name = $item if !$name; # if no VL name is specified, use item id as name

		if ($name && $statement) {
			my $virtualLibraryid = $item;
			my $file = $item;
			my %virtualLibrary = (
				'id' => $virtualLibraryid,
				'file' => $file,
				'name' => $name,
				'VLID' => 'PLUGIN_VLC_VLID_'.trim_all(uc($virtualLibraryid)),
				'external' => $external ? 1 : 0,
				'sql' => Slim::Utils::Unicode::utf8decode($statement, 'utf8'),
				'fulltext' => $external ? Slim::Utils::Unicode::utf8decode($fulltext, 'utf8') : '',
			);

			if ($isEnabled) {
				$virtualLibrary{'enabled'} = 1;
			}

			if ($dailyVLrefresh) {
				$virtualLibrary{'dailyvlrefresh'} = 1;
			}

			if ($libraryInitOrder) {
				$virtualLibrary{'libraryinitorder'} = $libraryInitOrder;
			}

			if (defined $browseMenusArtists && $browseMenusArtists ne '') {
				$virtualLibrary{'artistmenus'} = $browseMenusArtists;
			}
			if ($browseMenusArtistsHomeMenu) {
				$virtualLibrary{'artistmenushomemenu'} = 1;
			}
			if ($browseMenusArtistsHomeMenuWeight) {
				$virtualLibrary{'artistmenushomemenuweight'} = $browseMenusArtistsHomeMenuWeight;
			}

			if (defined $browseMenusAlbums && $browseMenusAlbums ne '') {
				$virtualLibrary{'albummenus'} = $browseMenusAlbums;
			}
			if ($browseMenusAlbumsHomeMenu) {
				$virtualLibrary{'albummenushomemenu'} = 1;
			}
			if ($browseMenusAlbumsHomeMenuWeight) {
				$virtualLibrary{'albummenushomemenuweight'} = $browseMenusAlbumsHomeMenuWeight;
			}

			if (defined $browseMenusMisc && $browseMenusMisc ne '') {
				$virtualLibrary{'miscmenus'} = $browseMenusMisc;
			}
			if ($browseMenusMiscHomeMenu) {
				$virtualLibrary{'miscmenushomemenu'} = 1;
			}
			if ($browseMenusMiscHomeMenuWeight) {
				$virtualLibrary{'miscmenushomemenuweight'} = $browseMenusMiscHomeMenuWeight;
			}

			if ((defined $browseMenusArtists && $browseMenusArtists ne '') || (defined $browseMenusAlbums && $browseMenusAlbums ne '') || (defined $browseMenusMisc && $browseMenusMisc ne '')) {
				$virtualLibrary{'hasbrowsemenus'} = 1;
			}

			if (defined $includedVLids && $includedVLids ne '') {
				$virtualLibrary{'includedvlids'} = $includedVLids;
			}
			if (defined $excludedVLids && $excludedVLids ne '') {
				$virtualLibrary{'excludedvlids'} = $excludedVLids;
			}

			return \%virtualLibrary;
		}

	} else {
		if ($@) {
			$errorMsg = "Incorrect information in virtualLibrary data: $@";
			$log->warn("Unable to read virtualLibrary configuration: $@");
		} else {
			$errorMsg = "Incorrect information in virtualLibrary data";
			$log->warn("Unable to to read virtualLibrary configuration");
		}
	}
	return undef;
}

sub parseVLname {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryName\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryName\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $VLnameString = $1;
		$VLnameString =~ s/^\s+//;
		$VLnameString =~ s/\s+$//;

		if ($VLnameString) {
			return $VLnameString;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseEnabled {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryEnabled\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryEnabled\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $enabledString = $1;
		$enabledString =~ s/^\s+//;
		$enabledString =~ s/\s+$//;

		if ($enabledString) {
			return 1;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseDailyRefresh {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryDailyVLrefresh\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryDailyVLrefresh\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $dailyRefreshString = $1;
		$dailyRefreshString =~ s/^\s+//;
		$dailyRefreshString =~ s/\s+$//;

		if ($dailyRefreshString) {
			return 1;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseLibraryInitOrder {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryInitOrder\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryInitOrder\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $initOrder = $1;
		$initOrder =~ s/^\s+//;
		$initOrder =~ s/\s+$//;

		if ($initOrder) {
			return $initOrder;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseArtistBrowseMenus {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusArtists\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusArtists\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $artistMenuString = $1;
		$artistMenuString =~ s/^\s+//;
		$artistMenuString =~ s/\s+$//;

		if ($artistMenuString) {
			return $artistMenuString;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseArtistMenusHomeMenuEnabled {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusArtistsHomeMenu\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusArtistsHomeMenu\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $menuEnabled = $1;
		$menuEnabled =~ s/^\s+//;
		$menuEnabled =~ s/\s+$//;

		if ($menuEnabled) {
			return 1;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseArtistMenusHomeMenuWeight {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusArtistsHomeMenuWeight\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusArtistsHomeMenuWeight\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $menuWeight = $1;
		$menuWeight =~ s/^\s+//;
		$menuWeight =~ s/\s+$//;

		if ($menuWeight) {
			return $menuWeight;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseAlbumBrowseMenus {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusAlbums\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusAlbums\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $albumMenuString = $1;
		$albumMenuString =~ s/^\s+//;
		$albumMenuString =~ s/\s+$//;

		if ($albumMenuString) {
			return $albumMenuString;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseAlbumMenusHomeMenuEnabled {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusAlbumsHomeMenu\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusAlbumsHomeMenu\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $menuEnabled = $1;
		$menuEnabled =~ s/^\s+//;
		$menuEnabled =~ s/\s+$//;

		if ($menuEnabled) {
			return 1;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseAlbumMenusHomeMenuWeight {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusAlbumsHomeMenuWeight\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusAlbumsHomeMenuWeight\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $menuWeight = $1;
		$menuWeight =~ s/^\s+//;
		$menuWeight =~ s/\s+$//;

		if ($menuWeight) {
			return $menuWeight;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseOtherBrowseMenus {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusMisc\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusMisc\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $otherMenuString = $1;
		$otherMenuString =~ s/^\s+//;
		$otherMenuString =~ s/\s+$//;

		if ($otherMenuString) {
			return $otherMenuString;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseOtherMenusHomeMenuEnabled {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusMiscHomeMenu\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusMiscHomeMenu\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $menuEnabled = $1;
		$menuEnabled =~ s/^\s+//;
		$menuEnabled =~ s/\s+$//;

		if ($menuEnabled) {
			return 1;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseOtherMenusHomeMenuWeight {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryBrowseMenusMiscHomeMenuWeight\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryBrowseMenusMiscHomeMenuWeight\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $menuWeight = $1;
		$menuWeight =~ s/^\s+//;
		$menuWeight =~ s/\s+$//;

		if ($menuWeight) {
			return $menuWeight;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseIncludedVLidString {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryIncludedVLs\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryIncludedVLs\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $VLidString = $1;
		$VLidString =~ s/^\s+//;
		$VLidString =~ s/\s+$//;

		if ($VLidString) {
			return $VLidString;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub parseExcludedVLidString {
	my $line = shift;

	if ($line =~ /^\s*--\s*VirtualLibraryExcludedVLs\s*[:=]\s*/) {
		$line =~ m/^\s*--\s*VirtualLibraryExcludedVLs\s*[:=]\s*([^:]+)\s*(.*)$/;
		my $VLidString = $1;
		$VLidString =~ s/^\s+//;
		$VLidString =~ s/\s+$//;

		if ($VLidString) {
			return $VLidString;
		} else {
			$log->warn("Error in parameter: $line");
			return undef;
		}
	}
	return undef;
}

sub externalCheck {
	my $filename = shift;
	my $dir = $prefs->get('customvirtuallibrariesfolder');
	my $path = catfile($dir, $filename.'.customvalues.xml');
	if (-f $path) {
		return undef;
	} else {
		return 1;
	}
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}

*escape = \&URI::Escape::uri_escape_utf8;

1;
