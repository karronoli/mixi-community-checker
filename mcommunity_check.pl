use strict;
use warnings;
use utf8;

use Encode;
use MIME::Base64;
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
our %config;
BEGIN {
    %config = do 'config.dat' or die "BAD cofig.dat!";
}

{
    # ref: http://yoosee.net/d/archives/2004/08/25/002.html
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
                SSL_version     =>      "TLSv1")){
                        croak "Couldn't start TLS: ".IO::Socket::SSL::errstr."\n
";
        }
        $me->hello();
    };
};

my $content = do {
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

my %node = do {
    my %result;
    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($content) or die $!;
    my @dt = $tree->findnodes(q{//div[@id='newCommunityTopic']//dt});
    for my $dt (@dt) {
        my ($a) = $dt->findnodes(q{./following-sibling::dd/a[1]});
        my $uri = URI->new($a->attr('href'));
        my %q = $uri->query_form;
        my $date = ($dt->as_text =~ /:/)?
          strftime(MIXI_DATE_TEMPLATE, localtime): $dt->as_text;
        $result{$q{id}} =
          {comment_count => $q{comment_count},
           date => $date,
           title => $a->as_text};
    }
    %result;
};
unless (%node) {
    warn "BAD community page layout.\n";
    exit(MIXI_BAD_STATUS);
}

# 削除はurlのクエリ部分から判定できない comment_count と date 変化無
# throw IronHTTPCallException
my @node_id = do {
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
            $node{$_} &&
              ($node{$_}->{comment_count} ne $old{$_}->{comment_count})
              || $node{$_}->{date} ne $old{$_}->{date}
          } keys %old;
        my @new = grep { !$old{$_} } keys %node;
        push @result, @update, @new;
    } else {
        push @result, keys %node;
    }
    my $item = IO::Iron::IronCache::Item->new(value => nfreeze(\%node));
    $iron_cache->put(key => $config{IRON_CACHE_KEY}, item => $item);
    sort {$node{$b}->{date} cmp $node{$a}->{date}} @result;
};
unless (@node_id) {
    print "No update\n";
    exit(MIXI_NO_UPDATE_STATUS);
}

my $mime = MIME::Entity->build
  (Type  => 'text/plain',
   Encoding => '-SUGGEST',
   From => $config{SMTP_FROM},
   To => $config{SMTP_TO},
   Subject => encode('MIME-Header-ISO_2022_JP',
                     strftime($config{MAIL_TITLE}, localtime)),
   Data =>
   [map {encode_utf8($_)}
    @{$config{MAIL_HEADERS}},
    (map {
        my %n = %{$node{$_}};
        # date:2014/12/08, title:test, comment:3
        sprintf($config{MAIL_UPDATE_TEMPLATE},
                $n{date}, $n{title}, $n{comment_count})
    } @node_id),
    @{$config{MAIL_FOOTERS}}
   ]);

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
