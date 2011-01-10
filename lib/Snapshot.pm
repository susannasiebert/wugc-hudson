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
	my $source_dirs = delete $params{source_dirs} || die;
	my $revisions = delete $params{revisions};
	my $overwrite = delete $params{overwrite};

	if (my @params_keys = keys %params) {
		die "Invalid params passed to Snapshot->new: '" . join(', ', @params_keys) . "'\n";
	}

    my $self = {
        snapshot_dir => $snapshot_dir,
		source_dirs => $source_dirs,
		revisions => $revisions,
		overwrite => $overwrite,
    };

    bless $self, $class;
    return $self;
}

sub open {
	my $class = shift;
	my $snapshot_dir = shift;
	my @source_dirs = File::Slurp::read_file("$snapshot_dir/source_dirs.txt") if (-s "$snapshot_dir/source_dirs.txt");
	my @revisions = File::Slurp::read_file("$snapshot_dir/revisions.txt") if (-s "$snapshot_dir/revisions.txt");
	my (%revisions) = map { split(" ", $_) } @revisions;
	return $class->new(snapshot_dir => $snapshot_dir, source_dirs => \@source_dirs, revisions => \%revisions);
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
	my @source_dirs = @{ $self->{source_dirs} };
	
	for my $source_dir (@source_dirs) {
		unless ( -d $source_dir ) {
			die "Error: $source_dir is not a directory.\n";
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
	my @source_dirs = @{ $self->{source_dirs} };
	
	unless ( system("mkdir -p $snapshot_dir") == 0 ) {
		die "Error: failed to create directory: '$snapshot_dir'.\n";
	}
	
	unless ( File::Slurp::write_file("$snapshot_dir/source_dirs.txt", join("\n", @source_dirs) . "\n") ) {
		die "Error: failed to write $snapshot_dir/source_dirs.txt.\n";
	}
	
	my @revisions;
	for my $source_dir (@source_dirs) {
        my $name_cmd = "cd $source_dir && " . Defaults::GIT_BIN() . " remote -v | grep origin | head -n 1 | awk '{print \$2}' | sed -e 's|.*/||' -e 's|\.git.*||'";
		my $origin_name = qx[$name_cmd];
		chomp $origin_name;
        my $hash_cmd = "cd $source_dir && " . Defaults::GIT_BIN() . " log | head -n 1 | awk '{print \$2}'";
		my $origin_hash = qx[$hash_cmd];
		chomp $origin_hash;
		push @revisions, "$origin_name $origin_hash";
	}
	my (%revisions) = map { split(" ", $_) } @revisions;
	$self->{revisions} = \%revisions;
	unless ( File::Slurp::write_file("$snapshot_dir/revisions.txt", join("\n", @revisions) . "\n") ) {
		die "Error: failed to write $snapshot_dir/revisions.txt.\n";
	}
	
	for my $source_dir (@source_dirs) {
		unless ( system("rsync -rltoD --exclude .git $source_dir/ $snapshot_dir/") == 0 ) {
			die "Error: failed to rsync $source_dir.\n";
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
	
	for my $unwanted_file ('.gitignore', 'Changes', 'INSTALL', 'LICENSE', 'MANIFEST', 'META.yml', 'Makefile.PL', 'README', 'lib/perl/*-POD') {
		system("rm -f $snapshot_dir/$unwanted_file");
	}

	for my $unwanted_dir ('debian', 'doc', 'inc', 't', 'test_results') {
		system("rm -rf $snapshot_dir/$unwanted_dir");
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
	if ( $move_to =~ /unstable/ ) {
		$dest_dir = Defaults::UNSTABLE_PATH() . "/$snapshot_name";
	} elsif ( $move_to =~ /tested/ ) {
		$dest_dir = Defaults::TESTED_PATH() . "/$snapshot_name";
	} elsif ( $move_to =~ /stable/ ) {
		$dest_dir = Defaults::STABLE_PATH() . "/$snapshot_name/";
	} else {
        die "Error: tried to move a directory to unrecognized location; $move_to does not match unstable/tested/stable.\n";
    }
	
	execute_or_die("rsync -rltoD $snapshot_dir/ $dest_dir/");
	for my $symlink (Defaults::CURRENT_USER(), Defaults::CURRENT_WEB(), Defaults::CURRENT_PIPELINE()) {
		if ( readlink($symlink) =~ /^$snapshot_dir\/?$/ ) {
			print "Updating symlink ($symlink) since we are moving the snapshot.\n";
			execute_or_die("ln -sf $dest_dir $symlink-new");
			execute_or_die("mv -Tf $symlink-new $symlink");
		}
	}
	execute_or_die("rm -rf $snapshot_dir/");

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
	
	if ( -d Defaults::STABLE_PATH() . "/$build_name" ) {
		$snapshot_path = Defaults::STABLE_PATH() . "/$build_name";
	} elsif ( -d Defaults::TESTED_PATH() . "/$build_name" ) {
		$snapshot_path = Defaults::TESTED_PATH() . "/$build_name";
	} elsif ( -d Defaults::CUSTOM_PATH() . "/$build_name" ) {
		$snapshot_path = Defaults::CUSTOM_PATH() . "/$build_name";
	} elsif ( -d Defaults::UNSTABLE_PATH() . "/$build_name") {
		$snapshot_path = Defaults::UNSTABLE_PATH() . "/$build_name";
	} elsif ( -d Defaults::OLD_PATH() . "/$build_name") {
		$snapshot_path = Defaults::OLD_PATH() . "/$build_name";
	} else {
		die "Unable to find $build_name in " . Defaults::BASE_DIR() . "/snapshots/{stable,tested,custom,unstable,old}\n";
	}
	
	return $snapshot_path;
}

1;

