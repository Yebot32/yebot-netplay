#!/usr/bin/perl
# Checks the iOS translations against the source. Usage: check_strings.pl <ios dir>
#
# A .strings file with a syntax error loses its whole language without a word, and a
# format specifier that differs from the English crashes or prints garbage only on
# the day someone runs that language. So, for every XS() and XSKey() in src/*.mm and
# every res/<lang>.lproj/Localizable.strings:
#   - the file parses, here, by a stricter reading than plutil's
#   - every key in the source is in every language
#   - no language keeps a key the source no longer has
#   - each translation has the same format specifiers as its key: the same types for
#     the same arguments, in any order if they are positional
# English has no file: the key is the text. Exits 1 on anything found.

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

my $ios = shift // 'ios';
my @problems;

# C and Objective-C literals in a source file, comments skipped, adjacent ones joined.
# Returns the text of each one that is the whole argument of XS() or XSKey().
sub keys_in {
  my ($path) = @_;
  open my $in, '<:encoding(UTF-8)', $path or die "$path: $!";
  local $/;
  my $src = <$in>;
  close $in;
  $src =~ s/\r\n/\n/g;
  # Comments out, literals kept. A // inside a URL literal must not start a comment.
  $src =~ s{("(?:[^"\\\n]|\\.)*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ' '}gse;
  my @found;
  while ($src =~ /\bXS(?:Key)?\(\s*((?:\@?"(?:[^"\\\n]|\\.)*"\s*)+)\)/g) {
    my $run = $1;
    my $text = '';
    $text .= $1 while $run =~ /"((?:[^"\\\n]|\\.)*)"/g;
    push @found, $text;
  }
  # An XS() around anything but a plain literal is not checkable. Say so.
  while ($src =~ /\bXS(?:Key)?\(\s*(?!\@?")([^)\n]*)/g) {
    next if $path =~ /XenraStrings\.h$/;
    push @problems, "$path: XS() of something that is not a literal: $1";
  }
  return @found;
}

# "key" = "value"; lines, comments allowed between them. Escapes are left as written.
sub read_strings {
  my ($path) = @_;
  open my $in, '<:encoding(UTF-8)', $path or do {
    push @problems, "$path: cannot be read";
    return {};
  };
  local $/;
  my $text = <$in>;
  close $in;
  my %table;
  pos($text) = 0;
  while (1) {
    $text =~ /\G(?:\s+|\/\*.*?\*\/|\/\/[^\n]*)*/gcs;
    last if pos($text) >= length $text;
    if ($text =~ /\G"((?:[^"\\\n]|\\.)*)"\s*=\s*"((?:[^"\\\n]|\\.)*)"\s*;/gc) {
      my ($key, $value) = ($1, $2);
      push @problems, "$path: \"$key\" is there twice" if exists $table{$key};
      $table{$key} = $value;
    } else {
      my $line = 1 + (substr($text, 0, pos($text)) =~ tr/\n//);
      push @problems, "$path:$line: syntax error, the language would be lost";
      last;
    }
  }
  return \%table;
}

# Argument number => type, for each specifier. %% is not one.
sub specifiers {
  my ($text) = @_;
  my %by_argument;
  my $next = 1;
  my @order;
  while ($text =~ /%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([\@dDiuUxXoOfFeEgGaAcCsSpn%])/g) {
    my ($position, $length, $type) = ($1, $2 // '', $3);
    next if $type eq '%';
    my $argument = defined $position ? $position : $next++;
    $by_argument{$argument} = $length . $type;
  }
  return join ' ', map { "$_:$by_argument{$_}" } sort { $a <=> $b } keys %by_argument;
}

my %source;
for my $path (sort glob("$ios/src/*.mm")) {
  $source{$_} = 1 for keys_in($path);
}
push @problems, "no XS() found under $ios/src" unless %source;

my @languages = sort glob("$ios/res/*.lproj");
push @problems, "no languages under $ios/res" unless @languages;

for my $folder (@languages) {
  my ($language) = $folder =~ m{([^/]+)\.lproj$};
  my $path = "$folder/Localizable.strings";
  my $table = read_strings($path);
  for my $key (sort keys %source) {
    if (!exists $table->{$key}) {
      push @problems, "$language: missing: $key";
      next;
    }
    my ($want, $have) = (specifiers($key), specifiers($table->{$key}));
    if ($want ne $have) {
      push @problems, "$language: format specifiers [$have] want [$want]: $key";
    }
  }
  for my $key (sort keys %$table) {
    push @problems, "$language: not in the source: $key" unless $source{$key};
  }
}

print "strings: ", scalar(keys %source), " keys, ", scalar(@languages), " languages\n";
print "$_\n" for @problems;
exit(@problems ? 1 : 0);
