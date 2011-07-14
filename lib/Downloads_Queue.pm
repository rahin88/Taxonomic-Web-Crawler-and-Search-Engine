package Downloads_Queue;

# provide one request at a time a crawler process

use strict;
use warnings;

use URI::Split;
use Fcntl qw (O_RDWR O_CREAT O_TRUNC);
use File::Path;
use Data::Dumper;
use Data::Serializer;
use DB;
use CConfig;
use Readonly;

#use Tie::File;
use Carp qw( croak confess );

# hash of { $download_media_id => { time => $last_request_time_for_media_id, pending => $pending_downloads }  }
my $_downloads = {};

Readonly my $download_timed_out_error_message => 'Download timed out by Fetcher::_timeout_stale_downloads';

my $_serializer;
my $_downloads_count = 0;

Readonly my $_debug_mode => 0;

sub new
{
    my ( $class ) = @_;

    my $self = {};
    bless( $self, $class );

    $_serializer = Data::Serializer->new();
    return $self;
}


sub _get_media_download_queue
{
    my ( $self, $media_id ) = @_;

    my @array;

    #my $file_name = $self->_get_download_queue_file_name($media_id);
    #tie @array, 'Tie::File', $file_name , mode => O_RDWR | O_CREAT | O_TRUNC || confess "error tying array: $!";
    my $ret = \@array;

    return $ret;
}

sub get_download_site_from_hostname
{
    my ( $host_name ) = @_;

    confess unless defined( $host_name );
    $host_name =~ s/.*\.([^.]*\.[^.]*)/$1/;

    return $host_name;
}

sub _queue_download
{
    my ( $self, $download ) = @_;
    my $media_id;


        my $host = $download->{ host };
        $host     = get_download_site_from_hostname( $host );
        $media_id = $host;    

    #print STDERR "Provider _queue_download media_id $media_id\n";

    $_downloads->{ $media_id }->{ queued } ||= $self->_get_media_download_queue( $media_id );
    $_downloads->{ $media_id }->{ time }   ||= 0;

    my $pending = $_downloads->{ $media_id }->{ queued };

    #my $download_serialized = $_serializer->freeze($download);


    if ( $download->{ priority } && ( $download->{ priority } > 0 ) )
    {
        unshift( @{ $pending }, $download );
    }
    else
    {
        push( @{ $pending }, $download );
    }


    $_downloads_count++;
}

# pop the latest download for the given media_id off the queue
sub _pop_download
{
    my ( $self, $media_id ) = @_;
    $_downloads->{ $media_id }->{ time } = time;
    $_downloads->{ $media_id }->{ queued } ||= [];
    
    my $download_serialized = shift( @{ $_downloads->{ $media_id }->{ queued } } );
    my $download            = $download_serialized;

    if ( $download )
    {
        $_downloads_count--;
    }

    return $download;
}

# get list of download media_id times in the form of { media_id => $media_id, time => $time }
sub _get_download_media_ids
{
    my ( $self ) = @_;
    
    return [ map{ { media_id => $_, time => $_downloads->{ $_ }->{ time } } } keys( %{ $_downloads } ) ];
}

sub _get_queued_downloads_count
{
    my ( $self, $media_id, $quiet ) = @_;

    unless ( defined( $quiet ) ) { print "_get_queued_downloads_count media='$media_id'\n"; }

    my $ret;

    if ( !defined( $_downloads->{ $media_id } ) || !$_downloads->{ $media_id } )
    {
        $ret = 0;
    }
    elsif ( !$_downloads->{ $media_id }->{ queued } )
    {
        $ret = 0;
    }
    else
    {
        $ret = scalar( @{ $_downloads->{ $media_id }->{ queued } } );
    }

    unless ( defined( $quiet ) ) { print "_get_queued_downloads_count media='$media_id' returning '$ret'\n"; }

    return $ret;
}

# sub _get_download_media_ids_under_queue_max
# {
#     my ($self, $queue_max) = @_;

#     return [ grep { scalar($_->{downloads}->{queued}) } key (%{$_downloads}) ];
# }

sub _verify_downloads_count
{
    my ( $self ) = @_;

    my $downloads_count_real = 0;

    for my $a ( values( %{ $_downloads } ) )
    {
        if ( @{ $a->{ queued } } )
        {
            $downloads_count_real += scalar( @{ $a->{ queued } } );
        }
    }

    die "\$_downloads_counts is $_downloads_count but there are actually $downloads_count_real downloads"
      unless $downloads_count_real == $_downloads_count;
}

# get total number of queued downloads
sub _get_downloads_size
{
    my ( $self ) = @_;

    if ( $_debug_mode )
    {
        $self->_verify_downloads_count();
    }
    return $_downloads_count;
}

1;
