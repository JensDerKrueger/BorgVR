use strict;
use warnings;
use FindBin;
use HTML::TreeBuilder;
use Test::More;

my $root = "$FindBin::Bin/../html";
for my $page (qw(interface.html index.html macos.html gsc.html mcp.html command-line.html server.html)) {
  my $tree = HTML::TreeBuilder->new;
  $tree->ignore_unknown(0);
  $tree->parse_file("$root/$page");
  my %ids;
  for my $element ($tree->look_down(sub { defined $_[0]->attr('id') })) {
    my $id = $element->attr('id');
    ok(!$ids{$id}++, "$page: unique anchor $id");
  }
  for my $element ($tree->look_down(sub { $_[0]->tag eq 'a' || $_[0]->tag eq 'img' || $_[0]->tag eq 'script' || $_[0]->tag eq 'link' })) {
    my $ref = $element->attr('href') // $element->attr('src');
    next unless defined $ref;
    next if $ref =~ m{^(?:[a-z]+:|//|\?)}i;
    my ($path, $anchor) = split /#/, $ref, 2;
    $path =~ s/\?.*//;
    my $target = length($path) ? "$root/$path" : "$root/$page";
    ok(-f $target, "$page: local resource $ref exists");
    if (defined $anchor && length($anchor) && $target =~ /\.html$/) {
      my $destination = HTML::TreeBuilder->new;
      $destination->ignore_unknown(0);
      $destination->parse_file($target);
      ok($destination->look_down(id => $anchor), "$page: target anchor $ref exists");
      $destination->delete;
    }
  }
  if ($page eq 'interface.html') {
    my @images = $tree->look_down(_tag => 'img', sub { ($_[0]->attr('src') // '') =~ m{screenshots/} });
    is(scalar @images, 10, 'Tour contains ten real screenshots, including clipping and before/after editing');
    for my $image (@images) {
      ok($image->attr('alt') && $image->attr('data-de-attr'), 'Screenshot has English and German alternative text');
      ok($image->attr('width') && $image->attr('height'), 'Screenshot reserves a stable aspect ratio');
      my %german = map { split /:/, $_, 2 } split /\|/, $image->attr('data-de-attr');
      like($image->attr('src'), qr{^\./screenshots/en/}, 'English page uses an English app capture');
      ok(defined $german{src} && -f "$root/$german{src}", 'German screenshot exists');
      isnt($image->attr('src'), $german{src}, 'Languages use separate app captures');
      is($image->parent->attr('href'), $image->attr('src'), 'Full-size link matches the English screenshot');
      is($image->parent->attr('data-de-attr'), "href:$german{src}", 'Full-size link matches the German screenshot');
    }
  }
  $tree->delete;
}
done_testing;
