=head1 NAME

mixi community checker

=head1 SYNOPSIS

Access mixi.jp, retrieve mixi community topics for mailing updates..

=cut

use strict;
use warnings;
use utf8;

use Encode;
use POSIX 'strftime';
use Storable qw(nfreeze thaw);

use WWW::Mechanize;
use HTML::TreeBuilder::XPath;
use URI;
use IO::Iron ();
use IO::Iron::IronCache::Client;
use IO::Iron::IronCache::Item;
use MIME::Entity;
use Net::SMTP::TLS;

use constant {
    MIXI_URL => 'http://mixi.jp/',
    MIXI_DATE_TEMPLATE => '%m月%d日',
    MIXI_BAD_STATUS => 1,
    MIXI_NO_UPDATE_STATUS => 2,
    IRON_CACHE_HOST => 'cache-aws-us-east-1.iron.io',
};
my %config;
BEGIN {
    %config = do 'config.dat' or die "BAD cofig.dat!";
}

{
    use Carp 'croak';
    no strict 'refs';
    no warnings 'redefine';
    *{'Net::SMTP::TLS::starttls'} = sub {
        my $me  = shift;
        $me->_command("STARTTLS");
        my ($num,$txt) = $me->_response();
        if(not $num == 220){
                croak "Invalid response for STARTTLS: $num $txt\n";
        }
        if(not IO::Socket::SSL::socket_to_SSL($me->{sock},
          SSL_version => '!SSLv23:!SSLv3:!SSLv2')){
                croak "Couldn't start TLS: ".IO::Socket::SSL::errstr."\n";
        }
        $me->hello();
    };
};

my $html = do {
    my $mech = WWW::Mechanize->new(autocheck => 1);
    $mech->get(MIXI_URL);
    $mech->submit_form(fields => {
        email => $config{MIXI_EMAIL},
        password => $config{MIXI_PASSWORD}
    });
    $mech->get(MIXI_URL . 'home.pl');
    $mech->get(MIXI_URL . 'view_community.pl?id=' . $config{MIXI_COMMUNITY_ID});
    $mech->content;
};

my %topics = do {
    my %result;
    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($html) or die $!;
    my @dt = $tree->findnodes(q{//div[@id='newCommunityTopic']//dt});
    for my $dt (@dt) {
        my ($a) = $dt->findnodes(q{./following-sibling::dd/a[1]});
        my $uri = URI->new($a->attr('href'));
        my %q = $uri->query_form;
        my $_date = ($dt->as_text =~ /:/)?
          strftime(MIXI_DATE_TEMPLATE, localtime): $dt->as_text;
        # strftime: Set UTF-8 flag appropriately on return
        # http://perl5.git.perl.org/perl.git/commit/9717af6d049902fc887c412facb2d15e785ef1a4
        # Fix on perl 5.20.1 and up.
        my $date = utf8::is_utf8($_date)?
          $_date: decode_utf8($_date, Encode::FB_CROAK);
        printf "[DEBUG] id:%s dt:%s date:%s\n",
          $q{id}, $dt->as_text, $date unless utf8::is_utf8($date);
        $result{$q{id}} =
          {comment_count => $q{comment_count},
           date => $date,
           title => $a->as_text};
    }
    %result;
};
unless (%topics) {
    warn "BAD community page layout.\n";
    exit(MIXI_BAD_STATUS);
}

# 削除はurlのクエリ部分から判定できない comment_count と date 変化無
# throw IronHTTPCallException
my @topic_ids = do {
    my @result;
    my $iron_cache = do {
        my $client = IO::Iron::IronCache::Client->new
          (host=> IRON_CACHE_HOST,
           project_id => $ENV{IRON_CACHE_PROJECT_ID}
           || $config{IRON_CACHE_PROJECT_ID},
           token => $ENV{IRON_CACHE_TOKEN}
           || $config{IRON_CACHE_TOKEN});
        local $@;
        my $ic = eval {
            $client->get_cache(name => $config{IRON_CACHE_NAME})
        };
        $@? $client->create_cache(name => $config{IRON_CACHE_NAME}): $ic;
    };

    local $@;
    if (my $old = eval{$iron_cache->get(key => $config{IRON_CACHE_KEY})}) {
        my %old = %{thaw $old->value};
        my @update = grep {
            exists $topics{$_} && ref $topics{$_} eq 'HASH'
              && ($topics{$_}->{comment_count} ne $old{$_}->{comment_count}
                  || $topics{$_}->{date} ne $old{$_}->{date})
          } keys %old;
        my @new = grep { !exists $old{$_}
                           && ref $old{$_} eq 'HASH' } keys %topics;
        push @result, @update, @new;
        my $old_item = IO::Iron::IronCache::Item->new(value => nfreeze(\%old));
        eval {
            $iron_cache->put(key => $config{IRON_CACHE_OLD_KEY},
                             item => $old_item)
        };
        warn $@ if $@;
    } else {
        push @result, keys %topics;
    }
    my $item = IO::Iron::IronCache::Item->new(value => nfreeze(\%topics));
    $iron_cache->put(key => $config{IRON_CACHE_KEY}, item => $item);
    sort {$topics{$b}->{date} cmp $topics{$a}->{date}} @result;
};
unless (@topic_ids) {
    print "No update\n";
    exit(MIXI_NO_UPDATE_STATUS);
}

my $mime = MIME::Entity->build
  (Type  => 'text/plain',
   Charset => 'UTF-8',
   Encoding => 'quoted-printable',
   From => "Notify <$config{SMTP_FROM}>",
   To => $config{SMTP_TO},
   Subject => encode('MIME-Header-ISO_2022_JP',
                     strftime($config{MAIL_TITLE}, localtime),
                     Encode::FB_CROAK | Encode::LEAVE_SRC),
   Data =>
   [encode_utf8(join '',
    $config{MAIL_HEADER},
    (map {
        my %t = %{$topics{$_}};
        # date:2014/12/08, title:test, comment:3
        sprintf($config{MAIL_UPDATE_TEMPLATE},
                $t{date}, $t{title}, $t{comment_count})
    } @topic_ids),
    $config{MAIL_FOOTER}
    )]);

my $smtp = Net::SMTP::TLS->new
  ($config{SMTP_HOST},
   Port => 587,
   Timeout => 20,
   User => $config{SMTP_USERNAME},
   Password => $config{SMTP_PASSWORD});
$smtp->mail($config{SMTP_FROM});
$smtp->to($config{SMTP_TO});
$smtp->data;
$smtp->datasend($mime->stringify);
$smtp->dataend;
$smtp->quit;
