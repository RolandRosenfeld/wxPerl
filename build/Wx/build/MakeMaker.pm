package Wx::build::MakeMaker;

use strict;
use Wx::build::Config;
use Wx::build::Options;
use ExtUtils::MakeMaker;
use base 'Exporter';
use vars qw(@EXPORT);

@EXPORT = 'wxWriteMakefile';

# sanitize File::Find on filesystems where nlink of directories is < 2
use File::Find;
$File::Find::dont_use_nlink = 1 if ( stat('.') )[3] < 2;

=head1 NAME

Wx::build::MakeMaker - ExtUtils::MakeMaker specialisation for wxPerl modules

=head1 METHODS

=head2 is_core

  if( is_core ) { ... }

True if it is building the wxPerl core (Wx.dll), false otherwise.

=head2 is_wxPerl_tree

  if( is_wxPerl_tree ) { ... }

True if it is building any part of wxPerl, false otherwise.

=cut

my $is_wxperl_tree = 0;

sub is_core() { -f 'Wx.pm' }
sub _set_is_wxPerl_tree { $is_wxperl_tree = $_[0] ? 1 : 0 }
sub is_wxPerl_tree { $is_wxperl_tree }

#   _call_method( 'method', $this, @args );
# calls the _core or _ext version of a method;
sub _call_method {
  my $name = shift;
  my $this = shift;
  $name .= is_core ? '_core' : '_ext';

  return $this->$name( @_ );
}

=head2 set_hook_package

  Wx::build::MakeMaker::set_hook_package( 'package_name' );

Package to be hooked into the MakeMaker inheritance chain.

=cut

# this is the default
my $hook_package = 'Wx::build::MakeMaker::' . Wx::build::Config->get_package;

sub set_hook_package {
  $hook_package = shift;
}

# this is a crude hack (at best), we put an arbitrary package
# into ExtUtils::MakeMaker inheritance chain in order to be able
# to customise it
sub import {
  undef *MY::libscan;
  # undef *MY::post_initialize;
  *MY::libscan = _make_hook( 'libscan' );
  # *MY::post_initialize = _make_hook( 'post_initialize' );

  Wx::build::MakeMaker->export_to_level( 1, @_ );
}

=head2 wx_config

  my $cfg = $this->wx_config();

Get the appropriate C<Wx::build::Config> object.

=cut

sub wx_config { $_[0]->{WX_CONFIG} }

sub _make_hook {
  my $hook_sub = shift;

  return sub {
    my $this = $_[0];
    my $class = ref $this;
    ( my $file = $hook_package ) =~ s{::}{/}g;
    no strict 'refs';
    require "$file.pm";
    undef *{"${class}::${hook_sub}"};
    unshift @{"${class}::ISA"}, $hook_package;

    $this->{WX_CONFIG} =
      Wx::build::Config->new( Wx::build::Options->
                              get_options( is_wxPerl_tree() ?
                                           'command_line' :
                                           'saved' ),
                              core => is_core(),
                              get_saved_options => !is_wxPerl_tree() );

    shift->$hook_sub( @_ );
  }
}

# this method calls ->configure
# in the appropriate Wx::build::MakeMaker::PACKAGE,
# and merges the results with its inputs
sub configure {
  ( my $file = $hook_package ) =~ s{::}{/}g;
  require "$file.pm";

  my $this = $_[0];
  my %cfg1 = %{$_[1]};
  my %cfg2 = _call_method( 'configure', $hook_package );
  my %cfg = Wx::build::Config->merge_config( \%cfg1, \%cfg2 );

  return \%cfg;
}

sub _make_override {
  my $name = shift;
  my $sub = sub {
    package MY;
    my $this = shift;
    my $full = "SUPER::$name";
    $this->$full( @_ );
  };
  no strict 'refs';
  *{"${name}_core"} = $sub;
  *{"${name}_ext"}  = $sub;
  *{"${name}"}      = sub { _call_method( $name, @_ ) };
}

_make_override( 'postamble' );
_make_override( 'depend' );
_make_override( 'libscan' );
_make_override( 'constants' );
sub ppd { package MY; shift->SUPER::ppd( @_ ) }
sub dynamic_lib { package MY; shift->SUPER::dynamic_lib( @_ ) }

use vars '%args';
sub _process_mm_arguments {
  local *args = $_[0];
  my $cfg =
    Wx::build::Config->new( Wx::build::Options->get_options( is_wxPerl_tree() ?
                                                             'command_line' :
                                                             'saved' ),
                            core => is_core(),
                            get_saved_options => !is_wxPerl_tree() );
  my $build = 1;
  my $platform = $cfg->get_wx_platform;
  my %options =
    %{ Wx::build::Options->get_makemaker_options( is_wxPerl_tree()
                                                  ? () : ( 'saved' ) ) };

  $args{CCFLAGS} = $options{extra_cflags};
  $args{LIBS} = $options{extra_libs};

  foreach ( keys %args ) {
    my $v = $args{$_};

    m/^WX_LIB$/ and do {
      $args{LIBS} .= join ' ',
        map { $cfg->get_contrib_lib( $_ ) }
          ( ref( $v ) ? ( @$v ) : ( $v ) );
      delete $args{$_};
    };

    m/^REQUIRE_WX$/ and do {
      $build &&= $cfg->get_wx_version() >= $v;
      delete $args{$_};
    };

    m/^(NO|ON)_WX_PLATFORMS$/ and do {
      my $on = $1 eq 'ON';

      if( $on ) {
        # build if platform is explicitly listed
        $build &&= grep { $_ eq $platform } @$v;
      } else {
        # build unless platform is explicitly listed
        $build &&= !grep { $_ eq $platform } @$v;
      }

      delete $args{$_};
    };

    m/^(?:ABSTRACT_FROM|AUTHOR)/ and do {
      # args not known prior to Perl 5.005_03 (the check is a bit conservative)
      delete $args{$_} if $ExtUtils::MakeMaker::VERSION < 5.43;
    };
  }

  return $build;
}

sub wxWriteMakefile {
  my %params = @_;

  $params{XSOPT}     = ' -C++ -noprototypes' .
    ( is_wxPerl_tree() ? ' -nolinenumbers ' : ' ' );
  $params{CONFIGURE} = \&Wx::build::MakeMaker::configure;
  require Wx::build::MakeMaker::Any_OS;
  push @{$params{TYPEMAPS} ||= []},
    File::Spec->catfile( Wx::build::MakeMaker::Any_OS->_api_directory,
                         'typemap' );

  my $build = Wx::build::MakeMaker::_process_mm_arguments( \%params );

  if( $build ) {
    WriteMakefile( %params );
  } else {
    ExtUtils::MakeMaker::WriteEmptyMakefile( %params );
  }
}

1;

# local variables:
# mode: cperl
# end: