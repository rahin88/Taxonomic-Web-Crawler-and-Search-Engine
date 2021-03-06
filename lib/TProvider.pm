package TProvider;

# provide one request at a time a crawler process

use strict;
use warnings;

use URI::Split;

use Data::Dumper;
use Data::Serializer;
use List::MoreUtils;
use DB;
use Downloads_Queue;
use Readonly;
use Perl6::Say;
use Digest::MurmurHash;
use URI::Escape;
use XML::Writer;
use IO::File;
use XML::Simple;

# how often to download each feed (seconds)
use constant STALE_FEED_INTERVAL => 3 * 14400;

# how often to check for feeds to download (seconds)
use constant STALE_FEED_CHECK_INTERVAL => 600;

# timeout for download in fetching state (seconds)
use constant STALE_DOWNLOAD_INTERVAL => 300;

# how many downloads to store in memory queue
use constant MAX_QUEUED_DOWNLOADS => 20000;

# how often to check the database for new pending downloads (seconds)
use constant DEFAULT_PENDING_CHECK_INTERVAL => 60;

# how often to check downloads queue - seconds
use constant DOWNLOADS_QUEUE_CHECK_INTERVAL => 10;

# how often to check db for new requests to load a cache file - seconds
##TODO change it to 60 
use constant CACHE_FILE_LOADED_CHECK_INTERVAL => 5;


# download check
my $_last_downloads_queue_check = 0;

# load requests to cache from db
my $_last_cache_loaded_check = 0;

# last time a stale feed check was run
my $_last_stale_feed_check = 0;

# last time a stale download check was run
my $_last_stale_download_check = 0;

my $_last_timed_out_spidered_download_check = 0;

# last time a pending downloads check was run
my $_last_pending_check = 0;

# has setup run once?
my $_setup = 0;

# hash of { $download_media_id => { time => $last_request_time_for_media_id,
#                                   pending => $pending_downloads }  }
my $_downloads = {};

Readonly my $download_timed_out_error_message => 'Download timed out by Fetcher::_timeout_stale_downloads';

my $_serializer;
my $_downloads_count = 0;

sub new
{
    my ( $class, $engine ) = @_;

    my $self = {};
    bless( $self, $class );
    $self->engine( $engine );

    $self->{ downloads } = Downloads_Queue->new();
    return $self;
}

# run before forking engine to perform one time setup tasks
sub _setup
{
    my ( $self ) = @_;

    if ( !$_setup )
    {
        print STDERR "Provider single time setup\n";
        $self->_load_requests_to_file();
        
        $_setup = 1;        
        my $dbs = $self->engine->dbs;
        
##TODO load any config files and to be included in .yml file
		if(open SEEDS, "<seeds.txt")
			{
			print "read seeds \n";
			while (<SEEDS>) 
				{
					# print data out before storing
					my $url= $_;
					chomp($url);
			        my $encoded_url = Handler::standardize_url($url);
					$self->engine->dbs->create(
			                    'downloads',
			                    {
				                parent        => 0,
				                url           => $encoded_url,
				                host          => lc( ( URI::Split::uri_split( uri_unescape($encoded_url) ) )[ 1 ] ),
				                type          => 'archival_only',
				                sequence      => 0,
				                state         => 'queued',
				                download_time => 'now()',
				                extracted     => 'f',
				                mm_hash_url   => Digest::MurmurHash::murmur_hash($url)
				                }
								 );
				 }
			}
		if(open FEEDS, "<feeds.txt")
			{
			print "read seeds \n";
			while (<FEEDS>) 
				{
					# print data out before storing
					my $url= $_;
					chomp($url);
			        my $encoded_url = THandler::standardize_url($url);
					$self->engine->dbs->create(
			                    'feeds',
			                    {
				                url            => $encoded_url,
				                last_download_time => 'now()',
				                mm_hash_url    => Digest::MurmurHash::murmur_hash($url)
				                }
								 );
				 }
			}
		else
			{
				 print STDERR "no seed files \n";
			}
		my $dbs_result = $dbs->query( "SELECT * from downloads where state =  'queued'" );
		my @queued_downloads = $dbs_result->hashes();
		print "queued_downloads array length = " . scalar( @queued_downloads ) . "\n";
		for my $d ( @queued_downloads )
        {
            $self->{ downloads }->_queue_download( $d );
        }
    }
}

sub _timeout_stale_downloads
{
	#print STDERR "_timeout_stale_downloads";
    my ( $self ) = @_;
    
    if ( $_last_stale_download_check > ( time() - STALE_DOWNLOAD_INTERVAL ) )
    {
        return;
    }
    $_last_stale_download_check = time();
    
    my $dbs       = $self->engine->dbs;
    ##TODO  changed to downloads from downloads_media
    my @downloads = $dbs->query( "SELECT * from downloads where state = 'fetching' and download_time < (now() - interval '5 minutes')" )->hashes;
    
    for my $download ( @downloads )
    {
        $download->{ state }         = ( 'error' );
        $download->{ error_message } = ( $download_timed_out_error_message );
        $download->{ download_time } = ( 'now()' );
        $dbs->update_by_id( "downloads", $download->{ downloads_id }, $download );
        print STDERR "timed out stale download " . $download->{ downloads_id } . " for url " . $download->{ url } . "\n";
    }
}

# get all stale feeds and add each to the download queue
# this subroutine expects to be executed in a transaction
sub _add_stale_feeds
{
	my ( $self ) = @_;
	
    if ( ( time() - $_last_stale_feed_check ) < STALE_FEED_CHECK_INTERVAL )
    {
        return;
    }

    print STDERR "start _add_stale_feeds\n";

    $_last_stale_feed_check = time();

    my $dbs = $self->engine->dbs;

    my $constraint =
      "((last_download_time IS NULL " . "OR (last_download_time < (NOW() - interval ' " . STALE_FEED_INTERVAL .
      " seconds'))) " . "AND url LIKE 'http://%')";
    my @feeds = $dbs->query( "SELECT * FROM feeds WHERE " . $constraint )->hashes();

  DOWNLOAD:
    for my $feed ( @feeds )
    {
        if ( !$feed->{ url } || substr( $feed->{ url }, 0, 7 ) ne 'http://' )
        {

            # TODO: report an error?
            next DOWNLOAD;
        }

        my $priority = 0;
        if ( !$feed->{ last_download_time } )
        {
            $priority = 10;
        }

        my $host = lc( ( URI::Split::uri_split( $feed->{ url } ) )[ 1 ] );
        my $download = $self->engine->dbs->create(
            'downloads',
            {
                feeds_id      => $feed->{ feeds_id },
                url           => $feed->{ url },
                host          => $host,
                type          => 'feed',
                sequence      => 1,
                state         => 'queued',
                priority      => $priority,
                download_time => 'now()',
                extracted     => 'f'
            }
        );

        $self->{ downloads }->_queue_download( $download );

        # add a random skew to each feed so not every feed is downloaded at the same time
        my $skew = int( rand( STALE_FEED_INTERVAL / 4 ) ) - ( STALE_FEED_INTERVAL / 8 );
        $feed->{ last_download_time } = \"now() + interval '$skew seconds'";

        #print STDERR "updating feed: " . $feed->{feeds_id} . "\n";

        $dbs->update_by_id( 'feeds', $feed->{ feeds_id }, $feed );
    }

    print STDERR "end _add_stale_feeds\n";
	
}

#TODO combine _queue_download_list & _queue_download_list_per_site_limit
sub _queue_download_list
{
    my ( $self, $downloads ) = @_;

    for my $download ( @{ $downloads } )
    {
        $download->{ state } = ( 'queued' );
        $self->engine->dbs->update_by_id( 'downloads', $download->{ downloads_id }, $download );

        $self->{ downloads }->_queue_download( $download );
    }

    return;
}

my $_pending_download_sites;

sub _get_pending_downloads_sites
{
    my ( $self ) = @_;

    if ( !$_pending_download_sites )
    {
        $_pending_download_sites =
          $self->engine->dbs->query( "SELECT distinct(site) from downloads_sites where state='pending' " )->flat();

        print "Updating _pending_download_sites \n";
        #print Dumper($_pending_download_sites);
    }

    return $_pending_download_sites;
}

# add all pending downloads to the $_downloads list
sub _add_pending_downloads
{
    my ( $self ) = @_;

    my $interval = $self->engine->pending_check_interval || DEFAULT_PENDING_CHECK_INTERVAL;

    if ( $_last_pending_check > ( time() - $interval ) )
    {
        return;
    }
    $_last_pending_check = time();

    my $current_queue_size = $self->{ downloads }->_get_downloads_size;
    if ( $current_queue_size > MAX_QUEUED_DOWNLOADS )
    {
        print "skipping add pending downloads due to queue size ($current_queue_size)\n";
        return;
    }

    #print "Not skipping add pending downloads queue size($current_queue_size) \n";
    
    my @downloads_non_media =
      $self->engine->dbs->query( "SELECT * from downloads where state = 'pending' ORDER BY downloads_id limit ? ",
        int( int( MAX_QUEUED_DOWNLOADS ) / 2 ) )->hashes;
    $self->_queue_download_list_with_per_site_limit( \@downloads_non_media, 100000 );
    say "Queued " . scalar( @downloads_non_media ) . ' non_media downloads';

    my @sites = map { $_->{ media_id } } @{ $self->{ downloads }->_get_download_media_ids };

    #print Dumper(@sites);
    @sites = grep { $_ =~ /\./ } @sites;
    push( @sites, @{ $self->_get_pending_downloads_sites() } );
    @sites = List::MoreUtils::uniq( @sites );

    my $site_download_queue_limit = int( int( MAX_QUEUED_DOWNLOADS ) / ( scalar( @sites ) + 1 ) );

    for my $site ( @sites )
    {
        my $site_queued_downloads = $self->{ downloads }->_get_queued_downloads_count( $site, 1 );
        my $site_downloads_to_fetch = $site_download_queue_limit - $site_queued_downloads;

        next if ( $site_downloads_to_fetch < 0 );

        my @site_downloads = $self->_get_pending_downloads_for_site( $site, $site_downloads_to_fetch );

        $self->_queue_download_list( \@site_downloads );
    }
    
}


# return the next pending request from the downloads table
# that meets the throttling requirement
sub provide_downloads
{
    my ( $self ) = @_;
    sleep( 1 );
    
    $self->_setup();
    
    $self->_timeout_stale_downloads();
    
    $self->_add_stale_feeds();
	
    $self->_add_pending_downloads();
    
    my @downloads;
  MEDIA_ID:
    for my $media_id ( @{ $self->{ downloads }->_get_download_media_ids } )
    {
	#print "\n media id is $media_id ";
        # we just slept for 1 so only bother calling time() if throttle is greater than 1
        if ( ( $self->engine->throttle > 1 ) && ( $media_id->{ time } > ( time() - $self->engine->throttle ) ) )
        {
            print STDERR "provide downloads: skipping media id $media_id->{media_id} because of throttling\n";
            #skip;
            next MEDIA_ID;
        }
        
        foreach ( 1 .. 3 )
        {
            if ( my $download = $self->{ downloads }->_pop_download( $media_id->{ media_id } ) )
            {
            	#print "\n dumper is ",Dumper($download);
                push( @downloads, $download );
            }
        }
    }
    
    print STDERR "provided downloads: " . scalar( @downloads ) . " downloads\n";

    if ( !@downloads )
    {
        sleep( 10 );
    }
#    print @downloads."out 1\n";
    return \@downloads;
}

# calling engine
sub engine
{
    if ( $_[ 1 ] )
    {
        $_[ 0 ]->{ engine } = $_[ 1 ];
    }

    return $_[ 0 ]->{ engine };
}

1;
