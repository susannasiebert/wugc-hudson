package Snapshot;

use strict;
use warnings;
require File::Path;
require File::Slurp;

BEGIN {
    require Cwd;
	require File::Basename;
    my $lib_dir = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../lib/');
    unless (grep { $lib_dir eq Cwd::abs_path($_) } @INC) {
        push @INC, $lib_dir;
    }
}

require Library;
require Defaults;

sub new {
    my $class = shift;
	my (%params) = @_;
	my $snapshot_dir = delete $params{snapshot_dir} || die;
	my $submodules = delete $params{submodules};
	my $overwrite = delete $params{overwrite};

	if (my @params_keys = keys %params) {
		die "Invalid params passed to Snapshot->new: '" . join(', ', @params_keys) . "'\n";
	}

    my $self = {
        snapshot_dir => $snapshot_dir,
		submodules => $submodules,
		overwrite => $overwrite,
    };

    bless $self, $class;
    return $self;
}

sub open {
	my $class = shift;
	my $snapshot_dir = shift;
	return $class->new(snapshot_dir => $snapshot_dir);
}

sub create {
	my $class = shift;
	
	my $self;
	if ( ref $class ) {
		$self = $class;
	} else {
		$self = $class->new(@_);
	}
	
	my $snapshot_dir = $self->{snapshot_dir};
	my @submodules = @{ $self->{submodules} };
	
	for my $submodule (@submodules) {
		unless ( -d $submodule ) {
			die "Error: $submodule directory not found.\n";
		}
	}
	
	if ( -d $snapshot_dir ) {
		if ($self->{overwrite}) {
			unless ( system("rm -rf $snapshot_dir") == 0) {
				die "Error: failed to remove $snapshot_dir.\n";
			}
		} else {
			die "Error: $snapshot_dir already exists and overwrite was not specified.\n";
		}
	}
	
	$self->create_snapshot_dir;
	
	$self->post_create_cleanup;
	
	$self->update_tab_completion;
	
	return $self;
}

sub create_snapshot_dir {
	my $self = shift;
	my $snapshot_dir = $self->{snapshot_dir};
	my @submodules = @{ $self->{submodules} };
	
	unless ( system("mkdir -p $snapshot_dir") == 0 ) {
		die "Error: failed to create directory: '$snapshot_dir'.\n";
	}
	
    for my $dir ('.', @submodules) {
        for my $subdir ('bin', 'sbin', 'lib') {
            next unless (-d "$dir/$subdir");
            unless ( system("rsync -rltoD --exclude .git --exclude *.t $dir/$subdir/ $snapshot_dir/$subdir/") == 0 ) {
                die "Error: failed to rsync $dir/$subdir/.\n";
            }
        }
    }

    wait_for_path($snapshot_dir); # $snapshot_dir doesn't instantly show up on other NFS shares...
    my @dump_files = qx[find $snapshot_dir -iname '*sqlite3-dump'];
	push @dump_files, qx[find $snapshot_dir -iname '*sqlite3n-dump'];
	for my $sqlite_dump (@dump_files) {
	    chomp $sqlite_dump;
	    (my $sqlite_db = $sqlite_dump) =~ s/-dump//;
	    if (-e $sqlite_db) {
	        print "SQLite DB $sqlite_db already exists, skipping\n";
	    } else {
			print "Updating SQLite DB ($sqlite_db) from dump\n";
	        my $sqlite_path = $ENV{SQLITE_PATH} || 'sqlite3';
	        system("$sqlite_path $sqlite_db < $sqlite_dump");
	    }
	    unless ( wait_for_path($sqlite_db) ) {
	        die "Failed to reconstitute $sqlite_dump as $sqlite_db!\n";
	    }
	}
	
	return 1;
}

sub post_create_cleanup {
	my $self = shift;
	my $snapshot_dir = $self->{snapshot_dir};
	
	my @paths = glob("$snapshot_dir/lib/*");
	@paths = grep { $_ !~ /\/lib\/(?:perl|java)/ } @paths;
	for my $path (@paths) {
		(my $new_path = $path) =~ s/$snapshot_dir\/lib\//$snapshot_dir\/lib\/perl\//;
		unless ( system("mv $path $new_path") == 0 ) {
			die "Error: failed to move $path to $new_path.\n";
		}
	}

    for my $ext ('pl', 'sh') {
        my @files = glob("$snapshot_dir/bin/*.$ext");
        for my $file (@files) {
            (my $new_file = $file) =~ s/\.$ext$//;
            rename($file, $new_file);
        }
    }

    return 1;
}

sub update_tab_completion {
	my $self = shift;
	my $snapshot_dir = $self->{snapshot_dir};

	system("cd $snapshot_dir/lib/perl && ur update tab-completion-spec Genome\:\:Command");
	system("cd $snapshot_dir/lib/perl && ur update tab-completion-spec Genome\:\:Model\:\:Tools");
	system("cd $snapshot_dir/lib/perl && ur update tab-completion-spec UR\:\:Namespace\:\:Command");	
	system("cd $snapshot_dir/lib/perl && ur update tab-completion-spec Workflow\:\:Command");
	
	return 1;
}

sub move_to {
	my $self = shift;
	my $move_to = shift || die;
	my $snapshot_dir = $self->{snapshot_dir};
	
	(my $snapshot_name = $snapshot_dir) =~ s/.*\///;
	
	my $dest_dir;
	if ( $move_to =~ /tested/ ) {
		$dest_dir = Defaults::TESTED_PATH() . "/$snapshot_name";
	} elsif ( $move_to =~ /stable/ ) {
		$dest_dir = Defaults::STABLE_PATH() . "/$snapshot_name";
    } elsif ( $move_to =~ /old/ ) {
        $dest_dir = Defaults::OLD_PATH() . "/$snapshot_name";
	} else {
        die "Error: tried to move a directory to unrecognized location; $move_to does not match unstable/tested/stable.\n";
    }

	
    my $is_symlinked = 0;
    for my $symlink (Defaults::CURRENT_USER(), Defaults::CURRENT_WEB(), Defaults::CURRENT_PIPELINE()) {
        $is_symlinked = 1 if ( readlink($symlink) =~ /^$snapshot_dir\/?$/ );
    }
    if ($is_symlinked) {
        execute_or_die("rsync -rltoD $snapshot_dir/ $dest_dir/");
        for my $symlink (Defaults::CURRENT_USER(), Defaults::CURRENT_WEB(), Defaults::CURRENT_PIPELINE()) {
            if ( readlink($symlink) =~ /^$snapshot_dir\/?$/ ) {
                print "Updating symlink ($symlink) since we are moving the snapshot.\n";
                execute_or_die("ln -sf $dest_dir $symlink-new");
                execute_or_die("mv -Tf $symlink-new $symlink");
            }
        }
        execute_or_die("rm -rf $snapshot_dir/");
    }
    else {
        print "moving $snapshot_name to $dest_dir...\n";
        execute_or_die("mv -n $snapshot_dir $dest_dir/");
        if (-d $snapshot_dir) {
            die "ERROR: old directory still exists: $snapshot_dir\n"
        }
    }

    $self->{snapshot_dir} = $dest_dir;

    return 1;
}

sub wait_for_path {
	my $path = shift || die;
	my $max_time = shift || 300;
	my $count = 0;
	while ( not -e $path && $count <= $max_time) {
		sleep(1);
		$count++;
	}
	
	return ( -e $path );
}

sub execute_or_die {
	my $cmd = shift;
	
	unless ( $cmd ) {
		die "No command specified to execute_or_die\n";
	}
	
	my $exit = system($cmd);
	die "Error: exit code $? for '$cmd'" if $?;
	
	# print "Command exited $exit: $cmd\n";
	
	my $rv = 0;
	$rv = 1 if ( $exit == 0 );
	
	return $rv;
}

sub find_snapshot {
	my $build_name = shift;
	$build_name =~ s/genome-genome/genome/;
	my $snapshot_path;
	
    if ( -d Defaults::SNAPSHOTS_PATH() . "/$build_name" ) {
        $snapshot_path = Defaults::SNAPSHOTS_PATH() . "/$build_name";
    } elsif ( -d Defaults::STABLE_PATH() . "/$build_name" ) {
		$snapshot_path = Defaults::STABLE_PATH() . "/$build_name";
	} elsif ( -d Defaults::TESTED_PATH() . "/$build_name" ) {
		$snapshot_path = Defaults::TESTED_PATH() . "/$build_name";
	} elsif ( -d Defaults::CUSTOM_PATH() . "/$build_name" ) {
		$snapshot_path = Defaults::CUSTOM_PATH() . "/$build_name";
	} elsif ( -d Defaults::OLD_PATH() . "/$build_name") {
		$snapshot_path = Defaults::OLD_PATH() . "/$build_name";
	} else {
		die "Unable to find $build_name in " . Defaults::BASE_DIR() . "/snapshots/{,stable,tested,custom,unstable,old}\n";
	}
	
	return $snapshot_path;
}


1;

