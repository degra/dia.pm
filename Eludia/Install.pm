package Eludia::Install;

package main;

use Carp;
use Cwd;
use Data::Dumper;
use DBI;
use DBI::Const::GetInfoType;
use Term::ReadLine;
use Term::ReadPassword;
use Fcntl qw(:DEFAULT :flock);
use File::Find;
use File::Temp qw(tempfile);
use Text::Iconv;
use POSIX ('setuid');

################################################################################

sub decode_entities {

	require HTML::Entities;
	require File::Copy;
	
	my $encoding = $ARGV [1] || 'cp1251';

	open (I, $ARGV [0]) or die ("Can't open $ARGV[0]:$!\n");
	open (O, '>/tmp/decode_entities') or die ("Can't write to /tmp/decode_entities:$!\n");

	binmode (I, ":encoding($encoding)");
	binmode (O, ":encoding($encoding)");

	my $s = '';

	while (my $line = <I>) {

	    if ($line =~ s{\=[\r\n]*$}{}) {
		$s .= $line;
		next;
	    }

	    print O decode_entities ($s . $line);

	    $s = '';

	}

	close (O);
	close (I);

	move ('/tmp/decode_entities', $ARGV [0]);

}

################################################################################

sub _cd {

	$ARGV [0] =~ /^\[[\w\-]+\]$/ or return;
	
	my $appname = shift (@ARGV);
	
	$appname =~ s{\[}{};
	$appname =~ s{\]}{};
	
	my $httpd = _local_exec ("which apache; which httpd");
	
	my $config_file_option =  _local_exec ("apache -V | grep SERVER_CONFIG_FILE");
	
	$config_file_option =~ /\=\"(.*?)\"/;
	
	my $config_file = $1;
	
	my $include_line = _local_exec ("cat /etc/apache/httpd.conf | grep $appname/conf/httpd.conf");
	
	$include_line = (split /\n/, $include_line) [0];
	$include_line =~ s{Include}{};
	$include_line =~ s{conf/httpd.conf}{};
	$include_line =~ s{\"}{}g;
	$include_line =~ s{\s}{}g;
	
	chdir $include_line;

	_local_exec ("pwd");

}

################################################################################

sub _local_exec {

	my $line = $_[0];	
	$line =~ s{\-p\".*?\"}{-p********}g;

	print STDERR " {$line";

	my $time = time;
	my $stdout = `$_[0]`;
	my $timing = ', ' . (time - $time) . ' s elapsed.';
	
	if ($_[0] !~ /cat / && $stdout =~ /./) {
		$stdout =~ s{^}{  }gsm;
		print STDERR "\n$stdout }$timing\n";
	}
	else {
		print STDERR "}$timing\n";
	}

	return $stdout;
	
}

################################################################################

sub _master_exec {

	my ($preconf, $cmd) = @_;
	
	my $ms = $preconf -> {master_server};
	
	_local_exec (
		$ms -> {host} eq 'localhost' ? 
			$cmd : 
			"ssh -l$$ms{user} $$ms{host} '$cmd'"
	)
	
}

################################################################################

sub restore_local_libs {
	my ($path) = @_;
	$path ||= $ARGV [0];
	_log ("Unpacking $path...");
	_local_exec ("tar xzfm $path");
	_local_exec ("chmod -R a+rwx lib/*");
}

################################################################################

sub restore_local_i {

	my ($path) = @_;
	$path ||= $ARGV [0];

	my $local_preconf = _read_local_preconf ();

#	_log ("Removing i...");
#	_local_exec ("rm -rf docroot/i/*");
	_log ("Unpacking $path...");
	_local_exec ("tar xzfm $path");
	_local_exec ("chmod -R a+rwx docroot/i/*");
	
}

################################################################################

sub restore_local_db {

	my ($path) = @_;	
	$path ||= $ARGV [0];

	my $local_preconf = _read_local_preconf ();
	
	_log ("Unzipping $path...");
	_local_exec ("gunzip $path");
	$path =~ s{\.gz$}{};
	
	_log ("Feeding $path to MySQL...");
	_local_exec ("mysql -u$$local_preconf{db_user} -p\"$$local_preconf{db_password}\" $$local_preconf{db_name} < $path");

	_log ("DB restore complete.");
	
}

################################################################################

sub restore {
	restore_local (@_);
}

################################################################################

sub restore_local {

	my ($time, $skip_libs, $no_backup) = @_;
	$time ||= $ARGV [0];	
	$time ||= readlink 'snapshots/latest.tar.gz';

	$time =~ s{snapshots\/}{};
	$time =~ s{\.tar\.gz}{};
	
	backup_local () unless $no_backup;

	my $path = "snapshots/$time.tar.gz";
	-f $path or die "File not found: $path\n";
	_log ("Restoring $path on local server...");
	_log ("Unpacking $path...");
	_local_exec ("tar xzfm $path");

	$time =~ s{master_}{};

	my $local_preconf = _read_local_preconf ();
	my $local_conf    = _read_local_conf    ();
	
	unless ($skip_libs) {
		my $lib_path = 'lib/' . $local_conf -> {application_name} . '.' . $time . '.tar.gz';
		restore_local_libs ($lib_path);
		_log ("Removing $lib_path...");
		_local_exec ("rm $lib_path");
	}
	
	if ($local_preconf -> {master_server} -> {static} eq 'none') {
		_log ("RESTORING STATIC FILES ON LOCAL SERVER IS SKIPPED.");
	}
	elsif ($local_preconf -> {master_server} -> {static} eq 'rsync') {
		my $s = $local_preconf -> {master_server};
		_log ("Synchronizing static files...");
		_local_exec ("rsync -r -essh $$s{user}\@$$s{host}:$$s{path}/docroot/i/* docroot/i/");
	} 
	else {
		my $i_path = 'docroot/i.' . $time . '.tar.gz';
		restore_local_i ($i_path);
		_log ("Removing $i_path...");
		_local_exec ("rm $i_path");
	}

	my $db_path = 'sql/' . $local_preconf -> {db_name} . '.' . $time . '.sql.gz';
	restore_local_db ($db_path);
	$db_path =~ s{\.gz$}{};
	_log ("Removing $db_path...");
	_local_exec ("rm $db_path");
	
}

################################################################################

sub timestamp {

	$time ||= time;

	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;

	return sprintf ("%4d-%02d-%02d-%02d-%02d-%02d", $year, $mon, $mday, $hour, $min, $sec);

}

################################################################################

sub _db_path {
	my ($db_name, $time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "sql/$db_name." . timestamp () . ".sql";
}

################################################################################

sub _lib_path {
	my ($application_name, $time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "lib/$application_name." . timestamp () . ".tar.gz";
}

################################################################################

sub _i_path {
	my ($time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "docroot/i." . timestamp () . ".tar.gz";
}

################################################################################

sub _snapshot_path {
	my ($time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "snapshots/" . timestamp () . ".tar.gz";
}

################################################################################

sub backup {
	backup_local (@_);
}




################################################################################

sub cleanup {

	_log ("Cleaning up logs...");
	_local_exec ("find -path '*/logs/*' -exec rm {} \\;");

	_log ("Cleaning up snapshots...");
	_local_exec ("find -path '*/snapshots/*' -exec rm {} \\;");

}

################################################################################

sub backup_local {

	my ($time) = @_;
	$time ||= time;
	_log ("Backing up application on local server...");
	my $db_path   = backup_local_db   ($time);
	my $libs_path = backup_local_libs ($time);
	my $i_path    = backup_local_i    ($time);
	my $path      = _snapshot_path    ($time);
	my $ln_path   = $path;
	$ln_path =~ s{^snapshots/}{};
	
	_log ("Creating $path...");
	_local_exec ("tar czf $path $db_path $libs_path $i_path");

	_log ("Creating symlink snapshots/latest.tar.gz...");
	_local_exec ("rm snapshots/latest.tar.gz*");
	_local_exec ("ln -s $ln_path snapshots/latest.tar.gz");
	
	_log ("Removing $db_path...");
	_local_exec ("rm $db_path");
	
	_log ("Removing $libs_path...");
	_local_exec ("rm $libs_path");
	
	if ($i_path) {
		_log ("Removing $i_path...");
		_local_exec ("rm $i_path");
	}

	_log ("Backup complete");
	return $path;
	
}

################################################################################

sub sync_down {

	my $time = time;

	my $snapshot_path = backup_master ();
	
	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();		

	_log ("Copying $snapshot_path from master...");
	_cp_from_master ($local_preconf, $local_preconf -> {master_server} -> {path} . '/' . $snapshot_path, 'snapshots/');
	
	restore_local ($snapshot_path, $local_preconf -> {master_server} -> {skip_libs}, 1);

	my $timing = ', ' . (time - $time) . ' s elapsed.';

	_log ("Sync complete$timing\n");

}

################################################################################

sub _log {

	print "$_[0]\n";

}

################################################################################

sub sync_up {
		
	my $libs_path = backup_local_libs ();

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();		

	my $master_path = $local_preconf -> {master_server} -> {path};

	my $master_libs_path = backup_master_libs ();
	$master_libs_path =~ s{$master_path\/}{};	

	_log ("Removing $master_libs_path...");
	_master_exec ($local_preconf, "cd $master_path; rm $master_libs_path");

	_log ("Copying $libs_path to master...");
	_cp_to_master ($local_preconf, $libs_path, $local_preconf -> {master_server} -> {path} . '/' . $libs_path);

	_log ("Removing $libs on master...");
	_master_exec ($local_preconf, "cd $master_path; rm -rf libs/*");

	_log ("Unpacking $libs on master...");
	_master_exec ($local_preconf, "cd $master_path; tar xzfm $libs_path");

	_log ("Removing $libs_path on master...");
	_master_exec ($local_preconf, "cd $master_path; rm $libs_path");

	_log ("Removing $libs_path locally...");
	_local_exec ("rm $libs_path");

	_log ("Sync complete");
	
}

################################################################################

sub _cp_from_master {

	my ($conf, $from, $to) = @_;
	my $ms = $conf -> {master_server};
	
	my $ex = $ms -> {host} eq 'localhost' ? 
		"cp $from $to": 	
		"scp $$ms{user}\@$$ms{host}:$from $to";

	_local_exec ($ex);

}

################################################################################

sub _cp_to_master {

	my ($conf, $from, $to) = @_;
	my $ms = $conf -> {master_server};
	
	my $ex = $ms -> {host} eq 'localhost' ? 
		"cp $from $to": 	
		"scp $from $$ms{user}\@$$ms{host}:$to";
		
	_local_exec ($ex);

}

################################################################################

sub backup_master {

	my ($time) = @_;
	$time ||= time;
	_log ("Backing up application on master server...");
	
	my $local_preconf = _read_local_preconf ();	
	my $local_conf = _read_local_conf ();	
	
	my $master_preconf = _read_master_preconf ();
	my $master_path = $local_preconf -> {master_server} -> {path};
	
	my $db_path = backup_master_db ($time);
	$db_path =~ s{$master_path\/}{};
	
	my $libs_path = '';
	unless ($local_preconf -> {master_server} -> {skip_libs}) {
		$libs_path = backup_master_libs ($time);
		$libs_path =~ s{$master_path\/}{};	
	}	
	
	my $i_path = backup_master_i ($time);
	$i_path =~ s{$master_path\/}{};	

	my $path = _snapshot_path ($time);
	$path =~ s{snapshots\/}{snapshots\/master_};
	
	_log ("Creating $path...");
	_master_exec ($local_preconf, "cd $master_path; tar czf $master_path/$path $db_path $libs_path $i_path");
	
	_log ("Removing $db_path...");
	_master_exec ($local_preconf, "cd $master_path; rm $db_path");
	
	unless ($local_preconf -> {master_server} -> {skip_libs}) {
		_log ("Removing $libs_path...");
		_master_exec ($local_preconf, "cd $master_path; rm $libs_path");
	}
	
	if ($i_path) {
		_log ("Removing $i_path...");
		_master_exec ($local_preconf, "cd $master_path; rm $i_path");
	}
	
	_log ("Backup complete");
	
	return $path;
	
}

################################################################################

sub backup_local_db {

	my ($time) = @_;
	$time ||= time;
	my $local_preconf = _read_local_preconf ();	
	my $path = _db_path ($local_preconf -> {db_name}, $time);
	_log ("Backing up db $$local_preconf{db_name} on local server...");
	
	_local_exec ("mysqldump --add-drop-table -Keq -u$$local_preconf{db_user} -p\"$$local_preconf{db_password}\" $$local_preconf{db_name} | gzip > $path.gz");
		
	_log ("DB backup complete");
	return "$path.gz";
		
}

################################################################################

sub backup_master_db {

	my ($time) = @_;
	$time ||= time;	

	my $local_preconf = _read_local_preconf ();	
	my $local_conf = _read_local_conf ();	

	my $master_preconf = _read_master_preconf ();	
	my $path = $local_preconf -> {master_server} -> {path} . '/' . _db_path ($local_preconf -> {db_name}, $time);
	_log ("Backing up db $$master_preconf{db_name} on master server...");
	
	_log ("Listing tables...");	
	my $tables = _master_exec ($local_preconf, "mysql -u$$master_preconf{db_user} -p\"$$master_preconf{db_password}\" $$master_preconf{db_name} -se\"show tables\"");
	
	my %skip_tables = map {$_ => 1} @{$local_preconf -> {master_server} -> {skip_tables}};
			
	my @tables = split /\n/, $tables;
	
	map {s{\s}{}gsm} @tables;
	
	my $dump_cmd = '';
	
	foreach my $table (@tables) {
			
		my $opt = '-Keq';
		$opt .= 'd' if $skip_tables {$table};
				
		$dump_cmd .= "mysqldump $opt --add-drop-table -u$$master_preconf{db_user} -p\"$$master_preconf{db_password}\" $$master_preconf{db_name} $table >> $path; ";
#		$dump_cmd .= "nice -n19 mysqldump $opt --add-drop-table -u$$master_preconf{db_user} -p\"$$master_preconf{db_password}\" $$master_preconf{db_name} $table >> $path; ";
			
	}
	
	_log ("Dumping database...");
	_master_exec ($local_preconf, $dump_cmd);
					
	_log ("Gzipping $path...");
#	_master_exec ($local_preconf, "nice -n19 gzip $path");
	_master_exec ($local_preconf, "gzip $path");
	
	_log ("DB backup complete");
	return "$path.gz";
		
}

################################################################################

sub backup_local_libs {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();	
	my $local_conf = _read_local_conf ();

	my $path = _lib_path ($local_conf -> {application_name}, $time);

	_log ("Backing up libs on local server...");
	_local_exec ("tar czf $path lib/*");

	_log ("Lib backup complete");
	return $path;
		
}

################################################################################

sub backup_local_i {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();
		
	if ($preconf -> {master_server} -> {static} eq 'none' or $preconf -> {master_server} -> {static} eq 'rsync') {
		_log ("BACKING UP STATIC FILES ON LOCAL SERVER IS SKIPPED.");
		return '';
	}

	my $path = _i_path ($time);

	_log ("Backing up static files on local server...");
	_local_exec ("tar czf $path docroot/i/*");

	_log ("I backup complete");
	return $path;
		
}

################################################################################

sub backup_master_libs {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();

	my $master_conf = _read_master_conf ();

	my $path = $local_preconf -> {master_server} -> {path} . '/' . _lib_path ($local_conf -> {application_name}, $time);

	_log ("Backing up libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar czf $path lib/*");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; cp $path snapshots/latest-libs.tar.gz");

	_log ("Lib backup complete");
	return $path;
		
}

################################################################################

sub backup_master_i {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();

	if ($local_preconf -> {master_server} -> {static} eq 'none' or $local_preconf -> {master_server} -> {static} eq 'rsync') {
		_log ("BACKING UP STATIC FILES ON MASTER SERVER IS SKIPPED.");
		return '';
	}

	my $master_conf = _read_master_conf ();

	my $path = $local_preconf -> {master_server} -> {path} . '/' . _i_path ($time);

	_log ("Backing up i on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar czf $path docroot/i/*");

	_log ("I backup complete");
	return $path;
		
}

################################################################################

sub restore_master_libs {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();

	_log ("Deleting libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; rm -rf libs/*");

	_log ("Restoring libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar xzfm snapshots/latest-libs.tar.gz");

	_log ("Lib restore complete");
	return $path;
		
}

################################################################################

sub _read_master_conf {

	unless ($MASTER_CONF) {

		my $local_preconf = _read_local_preconf ();
		my $local_conf = _read_local_conf ();

		my $src = _master_exec ($local_preconf, 'cat ' . $local_preconf -> {master_server} -> {path} . "/lib/$$conf{application_name}/Config.pm");
		undef $conf;
		eval $src;
		$MASTER_CONF = $conf;
		
	}

	return $MASTER_CONF;

}

################################################################################

sub _read_master_preconf {

	unless ($MASTER_PRECONF) {

		my $local_preconf = _read_local_preconf ();
		my $local_conf = _read_local_conf ();

		my $src = _master_exec ($local_preconf, 'cat ' . $local_preconf -> {master_server} -> {path} . "/conf/httpd.conf");
		$MASTER_PRECONF = _decrypt_preconf ($src);

	}

	return $MASTER_PRECONF;
	
}

################################################################################

sub _read_local_preconf {

	unless ($LOCAL_PRECONF) {
	
		_cd ();

		-f 'conf/httpd.conf' or die "ERROR: httpd.conf not found. Please, first chdir to the webapp directory.\n";
		my $src = `cat conf/httpd.conf`;
		$LOCAL_PRECONF = _decrypt_preconf ($src);
		
	}

	return $LOCAL_PRECONF;
	
}

################################################################################

sub _read_local_conf {
	
	unless ($LOCAL_CONF) {

		_cd ();

		opendir (DIR, 'lib') || die "can't opendir lib: $!";
		my ($appname) = grep {(-d "lib/$_") && ($_ !~ /\./) } readdir (DIR);
		closedir DIR;
		do "lib/$appname/Config.pm";
		$conf -> {application_name} = $appname;
		
		$LOCAL_CONF = $conf;

	}
	
	return $LOCAL_CONF;
	
}

################################################################################

sub _decrypt_preconf {

	my ($src) = @_;
	
	$src =~ s{.*\<perl\s*\>}{}gism;
	$src =~ s{\</perl\s*\>.*}{}gism;

	my $preconf_src = '';

	if ($src =~ /\$preconf.*?\;/gsm) {
		$preconf_src = $&;
	}
	else {
		$src =~ /use \w+\:\:Loader[^\{]*(\{.*\})/gsm;
		$preconf_src = $1; 
		$preconf_src or die "ERROR: can't parse httpd.conf.\n";
		$preconf_src = "\$preconf = $preconf_src";
	}
		
	eval $preconf_src;
		
	$preconf -> {db_dsn}  =~ /database=(\w+)/ or die "Wrong \$preconf_src: $preconf_src\n";
	$preconf -> {db_name} = $1;
	
	if ($preconf -> {master_server}) {
		$preconf -> {master_server} -> {static} ||= 'tgz';
	}	
	
	return $preconf;
	
}

################################################################################

sub create {
	
	our $term = new Term::ReadLine 'Eludia application installation';
	
	my ($appname, $appname_uc, $instpath, $db, $user, $password, $admin_user, $admin_password, $dbh, $dsn, $application_dst, $conf_dsn, $driver_name);
	
	while (1) {
	
		while (1) {
			$appname = $term -> readline ('Application name (lowercase): ');
			last if $appname =~ /[a-z_]+/
		}

		$appname_uc = uc $appname;	

		my $default_instpath = "/var/projects/$appname";

		while (1) {
	
	
			$instpath = $term -> readline ("Installation path [$default_instpath]: ") || $default_instpath;
	
			if (-d $instpath) {
				print "Installation path exists.\n";
				next;
			}

			last if $instpath =~ /[\w\/]+/

		}
		
		while (1) {

			$dsn = $term -> readline ("DBI connection string for CREATE DATABASE or 'pg' for Postgres [DBI:mysql:mysql]: ") ||'DBI:mysql:mysql';
			
			last if $dsn eq 'pg';

			$admin_user = 
				$dsn =~ /^dbi\:Oracle/ ? 'SYS' : 
				$$ENV {USER};
				
			$admin_user = $term -> readline ("Database admin user (for CREATE DATABASE) [$admin_user]: ") || $admin_user;

			$admin_password = read_password ("\nDatabase admin password (for CREATE DATABASE): ");			
			
			if ($dsn =~ /^dbi\:Pg/ && $admin_user eq '') {
			
				setuid `perl -ne 'if (/^postgres:[^:*]:(\\d+)/) {print \$1}' < /etc/passwd`;

			}			

			eval {
				$dbh = DBI -> connect ($dsn, $admin_user, $admin_password, {RaiseError => 1, ora_session_mode => 2});
				$dbh -> ping ();
			};
			
			$@ or last;
			
			warn $@;

		}

		while (1) {
			$user = $term -> readline ("Database user (for regular use) [$appname]: ");
			$user = $appname if $user eq '';
			last if $user =~ /\w+/
		}
		
		$driver_name = $dsn eq 'pg' ? 'PostgreSQL' : $dbh -> get_info ($GetInfoType {SQL_DBMS_NAME});
		
		if ($driver_name eq 'Oracle') {
			
			$db = $user;
			
			$conf_dsn = $dsn;

		}
		elsif ($driver_name eq 'PostgreSQL') {
			
			$db = $user;

			$conf_dsn = "DBI:Pg:database=$db;host=localhost";

		}
		else {

			while (1) {
				$db = $term -> readline ("Database name [$appname]: ") || $appname;
				last if $db =~ /\w+/
			}
			
			$conf_dsn = "DBI:mysql:database=$db;mysql_read_default_file=/etc/mysql/my.cnf";

		}

		SVN: while (1) {

			$application_dst = $term -> readline ("Application SVN URL: ");
					
			my $ls = `svn ls $application_dst`;
					
			my %dirs = ();
		
			foreach (split /\s+/sm, $ls) {$dirs {$_} = 1};
		
			foreach my $dir (qw (docroot lib)) {
				next if $dirs {$dir . '/'};
				warn "$dir not found\n";
				next SVN;
			}
			
			last;
			
		}
				
		$password = random_password ();

		print <<EOT;
 Application name:   $appname
 Database name:      $db
 Database user:      $user
 SVN repository URL: $application_dst
EOT
			
		my $ok = $term -> readline ("Is everything in its right place? (yes / NO): ");
		
		last if $ok eq 'yes';
		
	}
	
	print "Creating database... ";
	
	if ($driver_name eq 'MySQL') {
	
		$dbh -> do ("CREATE DATABASE $db");
		$dbh -> do ("GRANT ALL ON $db.* to $user\@localhost identified by '$password'");
		
	} 
	elsif ($driver_name eq 'PostgreSQL') {

		`su postgres -c\"psql -c \\\"CREATE USER \\\\\\\"$user\\\\\\\" PASSWORD '$password'\\\" \"`;
		`su postgres -c\"createdb -E WIN1251 -O $user $db\"`; #"

	} 
	elsif ($driver_name eq 'Oracle') {

		$dbh -> do (<<EOS);
			CREATE USER $db
			  IDENTIFIED BY "$password"
			  DEFAULT TABLESPACE SYSTEM
			  TEMPORARY TABLESPACE TEMP
			  PROFILE DEFAULT
			  ACCOUNT UNLOCK
EOS

		foreach my $privilege (
			'CONNECT',
			'CTXAPP',
			'RESOURCE',
			'CREATE SESSION',
			'CREATE TABLE',
			'CREATE TRIGGER',
			'CREATE SEQUENCE',
			'QUERY REWRITE',
		) {
			$dbh -> do ("GRANT $privilege to $user");
		}
		
		$dbh -> do ("ALTER USER $user DEFAULT ROLE NONE");

	} 
	
	$dbh -> disconnect if $dbh;

	print "ok\n";

	print "Creating application directory... ";

	`mkdir $instpath`;

	print "ok\n";

	print "Checking out application directory... ";
	
	`svn co $application_dst $instpath`;
	
	`mkdir $instpath/conf`;
	`mkdir $instpath/logs`;

	open (TMP, ">.svnignore") or die ("Can't write to .svnignore: $!\n");
	print TMP "conf\nlogs\n";
	close (TMP);
	
	`svn ps svn:ignore -F .svnignore $instpath`;
	
	unlink '.svnignore';

	`mkdir $instpath/docroot/i/upload`;
	`chmod a+rwx $instpath/docroot/i/upload`;
	`mkdir $instpath/docroot/i/_skins`;
	`chmod a+rwx $instpath/docroot/i/_skins`;

	open (TMP, ">.svnignore") or die ("Can't write to .svnignore: $!\n");
	print TMP "_skins\nupload\n";
	close (TMP);

	`svn ps svn:ignore -F .svnignore $instpath/docroot`;
	
	unlink '.svnignore';

	print "ok\n";

	print "Writing conf... ";

	open (CONF, ">$instpath/conf/httpd.conf") or die ("Can't write to httpd.conf: $!\n");
	
	print CONF <<EOC;
DocumentRoot "$instpath/docroot"

DefaultType text/html

ErrorLog  $instpath/logs/error.log
CustomLog $instpath/logs/access.log combined

<perl> 

	use Eludia::Loader

	'$instpath/lib' => '$appname_uc' 
		
	, {

		db_dsn => "$conf_dsn",
		db_user => '$user',
		db_password => '$password',

		core_gzip => 1,	
		core_skin => 'TurboMilk',
		
#		master_server => {
		
#			user => 'master_user',
#			host => 'master_host',
#			path => '/var/vh/sample',
			
##			static      => 'rsync',
#			skip_tables => ['log'],
			
#		},

#		mail => {

#			host		=> 'smtp....',
##			user		=> '...',
##			password	=> '...',

#			options         => {Debug => 1},
			
#			from		=>  {label => 'R.O.B.O.T', mail => '...'},
##			to		=>  {label => 'Human', mail => '...'},

#		},


	};
      
</perl>

<Location />
   SetHandler  perl-script
   PerlHandler $appname_uc
</Location>

<Location /i>
   SetHandler default
   ExpiresActive on
   ExpiresDefault "now plus 1 days"
</Location>
EOC

	close (CONF);
	
	if ($^O ne 'MSWin32') {
		`chmod -R a+w $instpath`;
	}

	print <<EOT;

--------------------------------------------------------------------------------
Congratulations! A brand new bare bones Eludia.pm-based WEB application is 
insatlled successfully. 

Now you just have to add it to your Apache configuration. This may look 
like
	
	Listen 8000
	
	<VirtualHost _default_:8000>
		Include "$instpath/conf/httpd.conf"
	</VirtualHost>
	
in /etc/apache/httpd.conf. Don\'t forget to restart Apache. 

Best wishes. 

d.o.
--------------------------------------------------------------------------------

EOT

}
#'

################################################################################

sub random_password {

	my $password;

	my @chars = ('a' .. 'z', 'A' .. 'Z', 0 .. 9, qw (- _ % |), '#');
	
	srand;

 	for (my $i = 0; $i < ($_[0] || 8); $i++) {
		$password .= $chars [int rand (0 + @chars)];
	}
	
	return $password;
	
}

################################################################################

sub bin {

	my $app_path = getcwd ();
	
	warn "Application path is '$app_path'...\n";

	$app_path =~ /\w+$/;
	
	$app_name = $&;
	
	warn "Application name is '$app_name'...\n";
	
	mkdir "$app_path/bin";
	mkdir "$app_path/conf/nginx";
	
	our $term = new Term::ReadLine 'Scripts installation';
	
	my $max_requests_per_child;

	while (1) {

		($max_requests_per_child = $term -> readline ("Max requests per child: ")) =~ /^\d{1,5}$/ and last;

	}

	foreach my $name ('sea', 'sky') { bin_name ($app_path, $app_name, $max_requests_per_child, $name) }
	
	`chmod a+x $app_path/bin/*.sh`;
	
	warn "\nDone.\n";

}

################################################################################

sub bin_name {

	my ($app_path, $app_name, $max_requests_per_child, $name) = @_;
	
	my $min_port, $max_port;
	
	while (1) {

		($min_port = $term -> readline ("Minimum port for '$name' configuration: ")) =~ /^\d{2,5}$/ and last;

	}
	
	while (1) {

		($max_port = $term -> readline ("Maximum port for '$name' configuration: ")) =~ /^\d{2,5}$/ and last;

	}

	warn "\nMaking scripts for '$name' configuration...\n";
	
	open (F, ">$app_path/bin/ea_${app_name}_${name}_loop.sh");
	print F <<EOT;
#!/bin/bash

cd $app_path

while [ 1 ]; do 

	perl -MEludia::Content::HTTP::Server -e"start (':\$1', \$2)" 2>>logs/error.log 
	
done
EOT
	close (F);

	open (F, ">$app_path/bin/ea_${app_name}_${name}_start.sh");
	print F <<EOT;
#!/bin/bash

for PORT in `seq $min_port $max_port`; do

	${app_path}/bin/ea_${app_name}_${name}_loop.sh \$PORT $max_requests_per_child \&
	
	echo "ea_${app_name}_${name}_start: \$PORT is on"

done
EOT
	close (F);

	open (F, ">$app_path/bin/ea_${app_name}_${name}_stop.sh");
	print F <<EOT;
#!/bin/bash

cd $app_path

killall -9 ea_${app_name}_${name}_loop.sh

echo "ea_${app_name}_${name}_stop: loops are broken"

for PORT in `seq $min_port $max_port`; do

	PIDFILE="logs/\$PORT.pid"

	if [ -f \$PIDFILE ]; then 

		echo "ea_${app_name}_${name}_stop: \$PIDFILE found"

		PID=`cat \$PIDFILE`

		echo "ea_${app_name}_${name}_stop: pid for \$PORT is \$PID"

		kill \$PID;  

		echo "ea_${app_name}_${name}_stop: \$PID (must be) killed"

	else 

		echo "ea_${app_name}_${name}_stop: \$PIDFILE not found"

	fi

done 
EOT
	close (F);

	bin_name_nginx ($app_path, $app_name, $max_requests_per_child, $min_port, $max_port, $name);

	warn "\nDone with '$name' configuration.\n";

}

################################################################################

sub bin_name_nginx {

	my ($app_path, $app_name, $max_requests_per_child, $min_port, $max_port, $name) = @_;

	warn "\nMaking nginx config files for '$name' configuration...\n";

	open (F, ">$app_path/conf/nginx/${app_name}_${name}_upstream.conf");

	print F "upstream $app_name {\n";
	
	foreach $port ($min_port .. $max_port) {

		print F "	server 127.0.0.1:$port max_fails=3 fail_timeout=30s; \n";

	}

	print F "}\n";

	close (F);

	open (F, ">$app_path/conf/nginx/${app_name}_${name}_server.conf");
	print F <<EOT;
	
		root ${app_path}/docroot;

		location /i/ {
		    expires 30d;
		}

		location = / {
		    proxy_pass       http://$app_name;
		    proxy_set_header X_Forwarded_For \$remote_addr;
		    proxy_buffering  off;
		}

		location / {
		    return 403;
		}
		
EOT
	close (F);

	open (F, ">$app_path/conf/nginx/${app_name}_${name}_README.txt");
	print F <<EOT;
	
		include $app_path/conf/nginx/${app_name}_${name}_upstream.conf;
		
		server {
		
			# listen 80 ### or something
			
			# maybe some other directives
			
			include $app_path/conf/nginx/${app_name}_${name}_server.conf;
		
			# and all that lasts

		}
		
EOT
	close (F);

}

1;