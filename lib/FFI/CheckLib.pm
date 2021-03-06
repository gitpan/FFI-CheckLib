package FFI::CheckLib;

use strict;
use warnings;
use File::Spec;
use Carp qw( croak );
use base qw( Exporter );

our @EXPORT = qw( find_lib assert_lib check_lib check_lib_or_exit );

# ABSTRACT: Check that a library is available for FFI
our $VERSION = '0.04'; # VERSION


our $system_path;
our $os = $ENV{FFI_CHECKLIB_TEST_OS} || $^O;
our $dyna_loader = 'DynaLoader';

if($os eq 'MSWin32')
{
  $system_path = eval q{
    use Env qw( @PATH );
    \\@PATH;
  }; die $@ if $@;
}
else
{
  $system_path = eval q{
    require DynaLoader;
    \\@DynaLoader::dl_library_path;
  }; die $@ if $@;
}

our $pattern = [ qr{^lib(.*?)\.so.*$} ];

if($os eq 'cygwin')
{
  push @$pattern, qr{^cyg(.*?)(?:-[0-9]+)?\.dll$};
}
elsif($os eq 'MSWin32')
{
  $pattern = [ qr{^(?:lib)?(.*?)(?:-[0-9]+)?\.dll$} ];
}
elsif($os eq 'darwin')
{
  push @$pattern, qr{^lib(.*?)\.(?:dylib|bundle)$};
}

sub _matches
{
  my($filename, $path) = @_;
  foreach my $regex (@$pattern)
  {
    return [ $1, File::Spec->catfile($path, $filename) ] if $filename =~ $regex;
  }
  return ();
}


sub find_lib
{
  my(%args) = @_;
  
  croak "find_lib requires lib argument" unless defined $args{lib};

  # make arguments be lists.
  foreach my $arg (qw( lib libpath symbol verify ))
  {
    next if ref $args{$arg} eq 'ARRAY';
    if(defined $args{$arg})
    {
      $args{$arg} = [ $args{$arg} ];
    }
    else
    {
      $args{$arg} = [];
    }
  }
  
  my %missing = map { $_ => 1 } @{ $args{lib} };
  my %symbols = map { $_ => 1 } @{ $args{symbol} };
  my @path = (@{ $args{libpath} }, @$system_path);
  my @found;

  foreach my $path (@path)
  {
    next unless -d $path;
    my $dh;
    opendir $dh, $path;
    my @maybe = 
      # prefer non-symlinks
      sort { -l $a->[1] <=> -l $b->[1] }
      # filter out the items that do not match
      # the name that we are looking for
      grep { $missing{$_->[0]} }
      # get [ name, full_path ] mapping,
      # each entry is a 2 element list ref
      map { _matches($_,$path) } 
      # read all files from the directory
      readdir $dh;
    closedir $dh;
    
    # TODO: the FFI::Sweet implementation
    # has some aggresive techniques for
    # finding .dlls from .a files that may
    # be worth adopting.
    
    midloop:
    foreach my $lib (@maybe)
    {
      next unless $missing{$lib->[0]};
      
      foreach my $verify (@{ $args{verify} })
      {
        next midloop unless $verify->(@$lib);
      }
      
      delete $missing{$lib->[0]};
      
      foreach my $symbol (keys %symbols)
      {
        next unless do {
          require "$dyna_loader.pm";
          no strict 'refs';
          my $dll = &{"$dyna_loader\::dl_load_file"}($lib->[1],0);
          my $ok = &{"$dyna_loader\::dl_find_symbol"}($dll, $symbol) ? 1 : 0;
          &{"$dyna_loader\::dl_unload_file"}($dll);
          $ok;
        };
        delete $symbols{$symbol};
      }
      
      push @found, $lib->[1];
    }    
  }
  
  %symbols ? () : @found;
}


sub assert_lib
{
  die 'library not found' unless check_lib(@_);
}


sub check_lib_or_exit
{
  unless(check_lib(@_))
  {
    # TODO: could probably work on
    # diagnostics
    warn "library not found";
    exit;
  }
}


sub check_lib
{
  find_lib(@_) ? 1 : 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

FFI::CheckLib - Check that a library is available for FFI

=head1 VERSION

version 0.04

=head1 SYNOPSIS

  use FFI::CheckLib;
  
  check_lib_or_exit( lib => 'jpeg', symbol => 'jinit_memory_mgr' );
  check_lib_or_exit( lib => [ 'iconv', 'jpeg' ] );
  
  # or prompt for path to library and then:
  print "where to find jpeg library: ";
  my $path = <STDIN>;
  check_lib_or_exit( lib => 'jpeg', libpath => $path );

=head1 DESCRIPTION

This module checks whether a particular dynamic library is available for FFI to use.
It is modeled heavily on L<Devel::CheckLib>, but will find dynamic libraries
even when development packages are not installed.  It also provides a 
L<find_lib|FFI::CheckLib#find_lib> function that will return the full path to
the found dynamic library, which can be feed directly into L<FFI::Raw>.

Although intended mainly for FFI modules via L<FFI::Raw> and similar, this module
does not actually use any FFI to do its detection and probing.  This module does
not have any non-core dependencies other than L<Module::Build> on Perl 5.20 and
more recent.

=head1 FUNCTIONS

All of these take the same named parameters and are exported by default.

=head2 find_lib

This will return a list of dynamic libraries, or empty list if none were found.

=head3 lib

Must be either a string with the name of a single library or a reference to an array
of strings of library names.  Depending on your platform, C<CheckLib> will prepend
C<lib> or append C<.dll> or C<.so> when searching.

=head3 libpath

A string or array of additional paths to search for libraries.

=head3 symbol

A string or a list of symbol names that must be found.

=head3 verify

A code reference used to verify a library really is the one that you want.  It 
should take two arguments, which is the name of the library and the full path to the
library pathname.  It should return true if it is acceptable, and false otherwise.  
You can use this in conjunction with L<FFI::Raw> to determine if it is going to meet
your needs.  Example:

 use FFI::CheckLib;
 use FFI::Raw;
 
 my($lib) = find_lib(
   name => 'foo',
   verify => sub {
     my($name, $libpath) = @_;
     
     my $new = FFI::Raw->new(
       $lib, 'foo_new',
       FFI::Raw::ptr,
     );
     
     my $delete = FFI::Raw->new(
       $lib, 'foo_delete',
       FFI::Raw::void,
       FFI::Raw::ptr,
     );
     
     # return true if new returns
     # a pointer, not forgetting
     # to free it on success.
     my $ptr = $new->call();
     return 0 unless $ptr;
     $delete->call();
     return 1;
   },
 );

=head2 assert_lib

This behaves exactly the same as L<find_lib|FFI::CheckLib#find_lib>,
except that instead of returning empty list of failure it throws
an exception.

=head2 check_lib_or_exit

This behaves exactly the same as L<assert_lib|FFI::CheckLib#assert_lib>,
except that instead of dying, it warns (with exactly the same error message)
and exists.  This is intended for use in C<Makefile.PL> or C<Build.PL>

=head2 check_lib

This behaves exactly the same as L<find_lib|FFI::CheckLib#find_lib>, except that
it returns true (1) on finding the appropriate libraries or false (0) otherwise.

=head1 AUTHOR

Graham Ollis <plicease@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Graham Ollis.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
