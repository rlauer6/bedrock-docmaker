package Bedrock::DocMaker;

use strict;
use warnings;

use Amazon::Credentials;
use Amazon::S3;
use Bedrock qw(choose $BEDROCK_DIST_DIR to_boolean slurp_file);
use Bedrock::LoadConfig qw(load_config);
use Bedrock::Template;
use Bedrock::DocMaker::Git qw(fetch_latest_commit);
use Carp;
use Carp::Always;
use CLI::Simple::Constants qw(:booleans :chars);
use Cwd qw(getcwd);
use Data::Dumper;
use Data::NestedKey;
use English qw(-no_match_vars);
use File::Basename qw(basename);
use File::Copy qw(copy move);
use File::Path qw(make_path);
use File::Temp;
use JSON;
use List::Util qw(any);
use Markdown::Render;
use YAML;

__PACKAGE__->use_log4perl( level => 'info' );

use Readonly;

Readonly::Scalar our $DEFAULT_CONFIG_FILE => 'bedrock-docmaker.yml';

Readonly::Scalar our $DOCMAKER_ARTIFACTS => [
  qw(
    bedrock-docmaker.mk
    index.md
    README.roc
    style.css
    about.md
  )
];

use parent qw(CLI::Simple);

caller or __PACKAGE__->main();

########################################################################
sub cmd_new {
########################################################################
  my ($self) = @_;

  my ($project_name) = $self->get_args;

  die "usage: bedrock-docmaker new project-name\n"
    if !$project_name;

  my $config = $self->get_config;

  my $bucket    = $self->get_bucket;
  my $s3_bucket = $self->get_s3_bucket;

  my $list = eval { $s3_bucket->list_all_v2(); };

  die "ERROR: bucket is not empty...use --force to or remove items from bucket\n"
    if $list && !$self->get_force;

  die "A .bedrock-docmaker directory exists. Remove the directory to re-initialize\n"
    if !$self->get_force && -d '.bedrock-docmaker';

  my $index = { project => $project_name, components => {} };

  $self->set_index($index);

  $self->_save_index;

  return $self->cmd_init;
}

########################################################################
sub cmd_init {
########################################################################
  my ($self) = @_;

  die "ERROR: not a git project\n"
    if !-d '.git';

  my $commit = eval { fetch_latest_commit(getcwd); };

  die "ERROR: unable to determine commit history. Have you committed anything yet?\n$EVAL_ERROR"
    if !$commit || $EVAL_ERROR;

  my ($component) = $self->get_args;

  my $index = $self->_fetch_index;

  if ( !$component ) {
    my $name = ucfirst $commit->{name};
    $name =~ s/[_-]/ /xsmg;  # remove dashes and underscores

    my %repo_info = %{$commit};
    delete $repo_info{name};
    $repo_info{pages} = ['README.html'];

    $index->{components}->{$name} = \%repo_info;
  }

  die "ERROR: No index found...start a new project first.\nbedrock-docmaker -b bucke-name new project-name\n"
    if !$index;

  die "A .bedrock-docmaker directory exists. Remove the directory to re-initialize\n"
    if -d '.bedrock-docmaker';

  $self->_init_docmaker($component);

  $self->_add_component($component);

  $self->_save_index;

  return $self->cmd_list_index;
}

########################################################################
sub cmd_process {
########################################################################
  my ($self) = @_;

  my $content = $self->_fetch('index.md.in');

  my $index = $self->get_index();

  my $template = Bedrock::Template->new( $content, index => $index );

  my $output = $template->parse();

  my $renderer = Markdown::Render->new( markdown => $output );
  $renderer->finalize_markdown($renderer);

  print {*STDOUT} $renderer->render_markdown->print_html;

  return $SUCCESS;
}

########################################################################
sub cmd_add_component {
########################################################################
  my ($self) = @_;

  my ( $component, $file ) = $self->get_args;

  $self->_add_component( $component, $file );

  $self->_save_index;

  return $self->cmd_list_index;
}

########################################################################
sub cmd_config {
########################################################################
  my ($self) = @_;

  my ( $key, $value ) = $self->get_args;

  my $config = $self->get_config;

  my $nk = Data::NestedKey->new($config);

  if ( defined $value ) {
    $nk->set( $key => $value, last_updated => scalar localtime );
    $self->_save_config;
  }

  delete $config->{_config_path};

  no warnings 'once'; ## no critic

  local $Data::NestedKey::FORMAT = 'YAML';

  print {*STDOUT} $nk->as_string;

  return $SUCCESS;
}

########################################################################
sub cmd_update_overview {
########################################################################
  my ($self) = @_;

  my ( $title, $subtitle ) = $self->get_args;

  die "usage: bedrock-docmaker update-overview [title] [sub-title:link]\n"
    if !$title && !$subtitle;

  if ($subtitle) {
    my @parts = split /:/xsm, $subtitle;
    $subtitle = { $parts[0] => [ $parts[1] ] };
  }

  my $index    = $self->get_index;
  my @overview = %{ $index->[0] };
  $title //= $overview[0];

  $index->[0] = { $title => $subtitle // $overview[1] };

  $self->_save_index;

  return $self->cmd_list_index;
}

########################################################################
sub cmd_update_index {
########################################################################
  my ($self) = @_;

  my ( $name, $file ) = $self->get_args;
  my $component = $self->get_component // $self->get_config->{component};

  die "usage: bedrock-docmaker update-index component-name filename\n"
    if !$component || !$name || !$file;

  $self->_update_component( $component, $name, $file );

  $self->_save_index;

  return $self->cmd_list_index;
}

########################################################################
sub cmd_list_index {
########################################################################
  my ($self) = @_;

  print {*STDOUT} JSON->new->pretty->encode( $self->get_index );

  return $SUCCESS;
}

########################################################################
sub cmd_fetch_index_json {
########################################################################
  my ($self) = @_;

  return $SUCCESS;
}

########################################################################
sub cmd_put {
########################################################################
  my ($self) = @_;

  return $SUCCESS;
}

########################################################################
sub cmd_list {
########################################################################
  my ($self) = @_;

  my $s3_bucket = $self->get_s3_bucket;
  my $list      = eval { $s3_bucket->list_all_v2(); };

  if ( !$list || $EVAL_ERROR ) {
    die "ERROR: bucket empty or no such bucket\n" . $s3_bucket->errstr;
  }

  print {*STDERR} Dumper( [ list => $s3_bucket->list_all_v2() ] );

  return $SUCCESS;
}

########################################################################
sub cmd_fetch {
########################################################################
  my ($self) = @_;

  my ($key) = $self->get_args;

  $self->_fetch( $key, $key );

  print {*STDOUT} "$key\n";

  return $SUCCESS;
}

########################################################################
sub cmd_remove_component {
########################################################################
  my ($self) = @_;

  my ($component_name) = $self->get_args;

  my $components = $self->get_index->[1];

  delete $components->{Components}->{$component_name};

  $self->_save_index;

  return $self->cmd_list_index;

  return $SUCCESS;
}

########################################################################
sub cmd_remove_link {
########################################################################
  my ($self) = @_;

  my ( $component_name, $link_name ) = $self->get_args;

  die "usage: bedrock-docmaker remove-link component-name link-name\n"
    if !$component_name || !$link_name;

  $self->_remove_component_link( $component_name, $link_name );

  $self->_save_index;

  return $self->cmd_list_index;
}

########################################################################
sub init {
########################################################################
  my ($self) = @_;

  my $dist_dir = $self->get_dist_dir;
  $dist_dir //= "$BEDROCK_DIST_DIR/bedrock-docmaker";
  $self->set_dist_dir($dist_dir);

  # this will create a config file if one does not exist
  my $config = $self->_init_config;

  $self->_init_s3;

  $self->_init_bucket;

  return
    if $self->command =~ /^(?:init|new)$/xsm;

  die "initialize bedrock-docmaker first: bedrock-docmaker init component-name\n"
    if !-d '.bedrock-docmaker';

  $self->_fetch_index;

  return;
}

########################################################################
sub _save_config {
########################################################################
  my ( $self, $filename ) = @_;

  my %config = %{ $self->get_config };

  $filename //= $config{_config_path} // 'bedrock-docmaker.yml';

  delete $config{_config_path};
  delete $config{dist_dir};
  delete $config{'dist-dir'};

  return YAML::DumpFile( $filename, \%config );
}

########################################################################
sub _init_docmaker {
########################################################################
  my ( $self, $component ) = @_;

  make_path('.bedrock-docmaker/local');

  my $config = $self->get_config;
  $config->{s3} //= {};
  $config->{s3}{bucket} = $self->get_bucket;
  $config->{'dist-dir'} = $self->get_dist_dir;
  $config->{profile} //= $self->get_profil // 'default';
  $config->{'log-level'} = $self->get_log_level // 'info';

  if ( !$component ) {
    $component //= basename(getcwd);
    $component = ucfirst $component;
  }

  $config->{component} = $component;

  $self->_save_config( $config->{_config_path} // 'bedrock-docmaker.yml' );

  my $dist_dir  = $self->get_dist_dir;
  my $s3_bucket = $self->get_s3_bucket;

  foreach ( @{$DOCMAKER_ARTIFACTS} ) {
    # try to download the existing project artifacts
    my $retval = $s3_bucket->get_key_filename( $_, GET => ".bedrock-docmaker/$_" );

    if ( !$retval ) {
      my $src = "$dist_dir/$_";
      copy( $src, ".bedrock-docmaker/$_" )
        or die "ERROR: unable to copy $src => .bedrock-dockmaker/$_\n";

      $s3_bucket->add_key( $_, scalar slurp_file($_) );
    }
  }

  move( '.bedrock-docmaker/bedrock-docmaker.mk', 'bedrock-docmaker.mk' );

  # seed initial templates
  foreach (qw(README.roc about.md)) {
    copy( "$dist_dir/$_", ".bedrock-docmaker/local/$_" );
  }

  return;
}

########################################################################
sub _init_config {
########################################################################
  my ($self) = @_;

  my $config = eval {
    my $config_file = $self->get_config_file;

    if ( !$config_file ) {
      if ( -e $DEFAULT_CONFIG_FILE ) {
        $config_file = $DEFAULT_CONFIG_FILE;
      }
      else {
        $self->get_logger->warn('No configuration file found. Initializing default configuration.');
        my $dist_dir = $self->get_dist_dir;

        copy( "$dist_dir/bedrock-docmaker.yml", 'bedrock-docmaker.yml' )
          or die "ERROR: Could initialize bedrock-docmaker.yml\n";

        $config_file = 'bedrock-docmaker.yml';
      }
    }

    return load_config($config_file);
  };

  die $EVAL_ERROR
    if !$config || $EVAL_ERROR;

  $self->set_config($config);

  $self->get_logger->debug( Dumper( [ config => $config ] ) );

  return $config;
}

########################################################################
sub _init_s3 {
########################################################################
  my ($self) = @_;

  my $config = $self->get_config;

  my $profile = $self->get_profile;
  $profile //= $config->{profile};

  my $credentials = Amazon::Credentials->new( profile => $profile );

  my $s3 = Amazon::S3->new(
    { credentials      => $credentials,
      dns_bucket_names => to_boolean( $config->{s3}{dns_bucket_names} ),
      host             => $config->{s3}{host},
      secure           => to_boolean( $config->{s3}{secure} ),
      debug            => $ENV{DEBUG},
      log_level        => $ENV{DEBUG} ? 'debug' : 'warn',
    }
  );

  $self->set_s3($s3);

  return;
}

########################################################################
sub _add_component {
########################################################################
  my ( $self, $component_name, $file ) = @_;

  my $index = $self->get_index;

  $file //= 'README.html';
  $index->[1]->{Components} = { $component_name => [ $file, {} ] };

  return;
}

########################################################################
sub _update_component {
########################################################################
  my ( $self, $component_name, $name, $link ) = @_;

  my $index = $self->get_index;

  my $components = $index->[1]->{Components};

  my $component = $components->{$component_name};

  if ($name) {
    my $extra_links = $component->[1] // {};
    $link //= $name;

    $extra_links->{$name} = $link;
    $component->[1] = $extra_links;
  }
  elsif ( !$component ) {
    return $self->_add_component($component_name);
  }

  return;
}

########################################################################
sub _get_component {
########################################################################
  my ( $self, $component_name ) = @_;

  my $config = $self->get_config;
  $component_name //= $config->{component_name};

  my $index      = $self->get_index;
  my $components = $index->[1];

  return $components->{$component_name};
}

########################################################################
sub cmd_deploy {
########################################################################
  my ( $self, $component ) = @_;

  $component //= $self->get_config->{component};

  die "usage: bedrock-docmaker deploy [component-name]\n"
    if !$component;

  my @doc_files = $self->_find_docs;

  foreach my $file (@doc_files) {
    if ( -e $file ) {
      my $key = sprintf '/docs/%s/%s', $component, $file;
      $self->_upload_file( $key, $file );
    }
    else {
      $self->get_logger->warn('$file does not exist...skipping');
    }
  }

  return $SUCCESS;
}

########################################################################
sub _find_docs {
########################################################################
  my ( $self, $component_name ) = @_;

  my $component = $self->_get_component($component_name);
  my @doc_files = ( $component->[0], values @{ $component->[1] // {} } );

  return @doc_files;
}

########################################################################
sub _remove_component_link {
########################################################################
  my ( $self, $component_name, $name ) = @_;

  my $index = $self->get_index;

  my $component = $index->[1]->{Components}->{$component_name};

  my $extra_links = $component->[1];

  delete $extra_links->{$name};

  return;
}

########################################################################
sub _upload_file {
########################################################################
  my ( $self, $key, $file ) = @_;

  my $s3_bucket = $self->get_s3_bucket;

  $s3_bucket->add_key_filename( $key, $file );

  return;
}

########################################################################
sub _save_index {
########################################################################
  my ($self) = @_;

  my $s3_bucket = $self->get_s3_bucket;

  $s3_bucket->add_key( 'index.json', JSON->new->pretty->encode( $self->get_index ) );

  return;
}

########################################################################
sub _fetch {
########################################################################
  my ( $self, $key, $filename ) = @_;

  my $bucket = $self->get_s3_bucket;

  if ($filename) {
    $bucket->get_key_filename( $key, GET => $filename );
    return;
  }

  my $obj = $bucket->get_key($key);

  return $obj->{value};
}

########################################################################
sub _fetch_index {
########################################################################
  my ($self) = @_;

  my $index_raw = $self->_fetch('index.json');

  return
    if !$index_raw;

  my $index = eval { from_json($index_raw); };

  die "ERROR: could not deserialize index ($index_raw)\n$EVAL_ERROR"
    if !$index || $EVAL_ERROR;

  $self->set_index($index);

  return $index;
}

########################################################################
sub _init_bucket {
########################################################################
  my ($self) = @_;

  my $config = $self->get_config;

  my $bucket_name = $self->get_bucket;
  $bucket_name //= $config->{s3}{bucket};
  $self->set_bucket($bucket_name);

  die "ERROR: no bucket name\n"
    if !$bucket_name;

  my $bucket = $self->get_s3->bucket($bucket_name);
  $self->set_s3_bucket($bucket);

  return;
}

########################################################################
sub _update_index {
########################################################################
  my ($self) = @_;

  return;
}

########################################################################
sub main {
########################################################################

  Getopt::Long::Configure("prefix_pattern=--|-");

  my %commands = (
    'update-index'     => \&cmd_update_index,
    'update-overview'  => \&cmd_update_overview,
    'add-component'    => \&cmd_add_component,
    'update-index'     => \&cmd_update_index,
    'update-component' => \&cmd_update_index,
    'remove-component' => \&cmd_remove_component,
    'remove-link'      => \&cmd_remove_link,
    'list-index'       => \&cmd_list_index,
    config             => \&cmd_config,
    put                => \&cmd_put,
    fetch              => \&cmd_fetch,
    list               => \&cmd_list,
    init               => \&cmd_init,
    process            => \&cmd_process,
    new                => \&cmd_new,
  );

  my @option_specs = qw(
    bucket|b=s
    component|C=s
    config-file|c=s
    dist-dir|d=s
    force|f
    help|h
    log-level|l=s
    profile|p=s
  );

  my $default_options = {};

  my @extra_options = qw(s3 s3_bucket config index);

  my $cli = __PACKAGE__->new(
    commands        => \%commands,
    option_specs    => \@option_specs,
    default_options => $default_options,
    extra_options   => \@extra_options,
  );

  return $cli->run;
}

1;
