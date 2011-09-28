#!/usr/bin/env plackup
package ReadableURL;
use strict;
use warnings;
use lib lib => glob 'modules/*/lib';
require utf8;
use Encode;
use Web::URL::Canonicalize;
use Web::DomainName::Punycode;
BEGIN {
    $ENV{PLACK_ENV} = 'production';
};

sub percent_decode_c ($) {
  my $s = ''.$_[0];
  utf8::encode ($s) if utf8::is_utf8 ($s);
  $s =~ s/%([0-9A-Fa-f]{2})/pack 'C', hex $1/ge;
  require Encode;
  return Encode::decode ('utf-8', $s);
} # percent_decode_c

sub decode_percent_encoding_if_possible ($) {
    my $v = Encode::encode ('utf8', $_[0]);
    $v =~ s{%([2-9A-Fa-f][0-9A-Fa-f])}{
        my $ch = hex $1;
        if ([
            1, 1, 1, 1, 1, 1, 1, 1, # 0x00
            1, 1, 1, 1, 1, 1, 1, 1, # 0x08
            1, 1, 1, 1, 1, 1, 1, 1, # 0x10
            1, 1, 1, 1, 1, 1, 1, 1, # 0x18
            1, 1, 1, 1, 1, 1, 1, 1, # 0x20
            1, 1, 1, 1, 1, 0, 0, 1, # 0x28
            0, 0, 0, 0, 0, 0, 0, 0, # 0x30
            0, 0, 1, 1, 1, 1, 1, 1, # 0x38
            1, 0, 0, 0, 0, 0, 0, 0, # 0x40
            0, 0, 0, 0, 0, 0, 0, 0, # 0x48
            0, 0, 0, 0, 0, 0, 0, 0, # 0x50
            0, 0, 0, 1, 1, 1, 1, 0, # 0x58
            1, 0, 0, 0, 0, 0, 0, 0, # 0x60
            0, 0, 0, 0, 0, 0, 0, 0, # 0x68
            0, 0, 0, 0, 0, 0, 0, 0, # 0x70
            0, 0, 0, 1, 1, 1, 0, 1, # 0x78
        ]->[$ch]) {
            # PERCENT SIGN, reserved, not-allowed in ASCII
            '%'.$1;
        } else {
            chr $ch;
        }
    }ge;
    $v =~ s{(
        [\xC2-\xDF][\x80-\xBF] | # UTF8-2
        [\xE0][\xA0-\xBF][\x80-\xBF] |
        [\xE1-\xEC][\x80-\xBF][\x80-\xBF] |
        [\xED][\x80-\x9F][\x80-\xBF] |
        [\xEE\xEF][\x80-\xBF][\x80-\xBF] | # UTF8-3
        [\xF0][\x90-\xBF][\x80-\xBF][\x80-\xBF] |
        [\xF1-\xF3][\x80-\xBF][\x80-\xBF][\x80-\xBF] |
        [\xF4][\x80-\x8F][\x80-\xBF][\x80-\xBF] | # UTF8-4
        [\x80-\xFF]
    )}{
        my $c = $1;
        if (length ($c) == 1) {
            $c =~ s/(.)/sprintf '%%%02X', ord $1/ge;
            $c;
        } else {
            my $ch = Encode::decode ('utf8', $c);
            if ($ch =~ /^[\x{00A0}-\x{200D}\x{2010}-\x{2029}\x{202F}-\x{D7FF}\x{F900}-\x{FDCF}\x{FDF0}-\x{FFEF}\x{10000}-\x{1FFFD}\x{20000}-\x{2FFFD}\x{30000}-\x{3FFFD}\x{40000}-\x{4FFFD}\x{50000}-\x{5FFFD}\x{60000}-\x{6FFFD}\x{70000}-\x{7FFFD}\x{80000}-\x{8FFFD}\x{90000}-\x{9FFFD}\x{A0000}-\x{AFFFD}\x{B0000}-\x{BFFFD}\x{C0000}-\x{CFFFD}\x{D0000}-\x{DFFFD}\x{E1000}-\x{EFFFD}]/) {
                $c;
            } else {
                $c =~ s/([\x80-\xFF])/sprintf '%%%02X', ord $1/ge;
                $c;
            }
        }
    }gex;
    $v =~ s/([<>"{}|\\\^`\x00-\x20\x7F])/sprintf '%%%02X', ord $1/ge;
    return Encode::decode ('utf8', $v);
}

my $app = sub {
    my $env = shift;
    my $request_url = $env->{REQUEST_URI};

    my $body;
    if ($request_url =~ m{^/create(?:$|\?)}) {
        my %qs = map { map { percent_decode_c $_ } split /=/, $_, 2 }
            split /[&;]/, $env->{QUERY_STRING} || '';
        my $orig_url = $qs{url} || '';
        
        my $short_url = url_to_canon_url $orig_url, q<thismessage:/>;
        $short_url = decode_percent_encoding_if_possible $short_url;
        $short_url = encode_punycode $short_url;
        $short_url =~ s/([^\x2B-\x3B\x3D\x40-\x5A\x5F\x61-\x7A\x7E])/sprintf '%%%02X', ord $1/ge;
        if ($short_url =~ s{^https?://([0-9a-z_-]+)\.g\.hatena\.ne\.jp/}{}) {
            $short_url = q{/g/} . $1 . q{/} . $short_url;
        } elsif ($short_url =~ s{^http://}{}) {
            $short_url = q{/h/} . $short_url;
        } elsif ($short_url =~ s{^https://}{}) {
            $short_url = q{/s/} . $short_url;
        } else {
            $short_url = q{/u/} . $short_url;
        }
        $body = url_to_canon_url 'https://' . $env->{HTTP_HOST} . $short_url, q<thismessage:/>;
        return [200, ['Content-Type' => 'text/plain'], [encode 'utf-8', $body]];
    } elsif ($request_url =~ s{^/([uhs])/}{}) {
        my $type = $1;
        if ($type eq 'h') {
            $request_url = 'http://' . $request_url;
        } elsif ($type eq 's') {
            $request_url = 'https://' . $request_url;
        }
        $request_url = percent_decode_c $request_url;
        $request_url = decode_punycode $request_url;
        $request_url = url_to_canon_url $request_url;
        return [302, ['Location' => $request_url], []];
    } elsif ($request_url =~ s{^/g/([^/]+)/}{}) {
        $request_url = q<https://> . $1 . q<.g.hatena.ne.jp/> . $request_url;
        $request_url = percent_decode_c $request_url;
        $request_url = decode_punycode $request_url;
        $request_url = url_to_canon_url $request_url;
        return [302, ['Location' => $request_url], []];
    } else {
        return [200, ['Content-Type' => 'text/html; charset=utf-8'], [q{
          <!DOCTYPE HTML>
          <title>Generate readable URL</title>
          <form action="/create">
           <input type=url size=100 name=url value="">
          </form>
        }]];
    }
};

use Plack::Builder;
builder {
    open my $fh, ">>", "/var/log/plack/access_log" or die "cannot load log file: $!";
    select $fh; $|++; select STDOUT;
    enable 'Plack::Middleware::AccessLog', logger => sub { print { $fh } @_ };

    enable "Plack::Middleware::ReverseProxy";
#    enable "Plack::Middleware::ServerStatus";
    enable "Plack::Middleware::Head";

    $app;
}

=head1 AUTHOR

Wakaba <wakabatan@hatena.ne.jp>.

=head1 LICENSE

Copyright 2011 Hatena <http://www.hatena.ne.jp/>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
