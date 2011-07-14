package TEngine;

# core engine of crawler:
# * fork specified number of crawlers
# * get Requests from TProvider
# * provide Request to each waiting crawlers
#
# * with each crawler
#   * get Request from engine
#   * fetch Request with TFetcher
#   * handle Request with THandler
#   * repeat

use strict;
use warnings;

use Fcntl;
use IO::Select;
use IO::Socket;
use Data::Dumper;
use Time::HiRes;
use Perl6::Say;

use TFetcher;
use THandler;
use TProvider;

use constant DB_LABEL => "DB";

sub new
{
    my ( $class ) = @_;

    my $self = {};
    bless( $self, $class );

    $self->processes( 1 );
    $self->sleep_interval( 60 );
    $self->throttle( 30 );
    $self->fetchers( [] );
    $self->reconnect_db();

    return $self;
}

# continually loop through the provide, fetch, respond cycle
# for one crawler process
sub _run_fetcher
{
    my ( $self ) = @_;

    print STDERR "fetcher " . $self->fetcher_number . " crawl loop\n";

    $self->reconnect_db();

    my $fetcher = TFetcher->new( $self );
    my $handler = THandler->new( $self );

    my $download;

    $self->socket->blocking( 0 );

    while ( 1 )
    {
        my $download;
        eval {

            $download = 0;

            $self->reconnect_db;

            # tell the parent provider we're ready for another download
            # and then read the download id from the socket
            $self->socket->printflush( $self->fetcher_number() . "\n" );
            my $downloads_id = 0;
            $downloads_id = $self->socket->getline();

            if ( defined( $downloads_id ) )
            {
                chomp( $downloads_id );
            }

            if ( $downloads_id && ( $downloads_id ne 'none' ) )
            {
                # print STDERR "fetcher " . $self->fetcher_number . " get downloads_id: '$downloads_id'\n";
                $download = $self->dbs->find_by_id( 'downloads', $downloads_id );
                if ( !$download )
                {
                    die( "fetcher " . $self->fetcher_number . ": Unable to find download_id: $downloads_id" );
                }

                my $start_fetch_time = [ Time::HiRes::gettimeofday ];
                my $response = $fetcher->fetch_download( $download );
                my $end_fetch_time = [ Time::HiRes::gettimeofday ];

                eval { $handler->handle_response( $download, $response ); };

                my $fetch_time = Time::HiRes::tv_interval( $start_fetch_time,  $end_fetch_time );
                my $handle_time = Time::HiRes::tv_interval( $end_fetch_time );

                if ( $@ )
                {
                    die( "Error in handle_response() for downloads_id '$downloads_id' '" . $download->{ url } . "' : $@" );
                }

                print STDERR "fetcher " . $self->fetcher_number . " get downloads_id: '$downloads_id' " .
                    $download->{ url } . " complete [ $fetch_time / $handle_time ]\n";
            }
            else
            {
                sleep( 3 );
            }
        };

        if ( $self->dbs )
        {
            $self->dbs->commit;
        }

    }
}

# fork off the fetching processes
sub spawn_fetchers
{
    my ( $self ) = @_;

    for ( my $i = 0 ; $i < $self->processes ; $i++ )
    {
        my ( $parent_socket, $child_socket ) = IO::Socket->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC );

        die "Could not create socket for fetcher $i" unless $parent_socket && $child_socket;

        print STDERR "spawn fetcher $i ...\n";
        my $pid = fork();

        if ( $pid )
        {
            $child_socket->close();
            $self->fetchers->[ $i ] = { pid => $pid, socket => $parent_socket };
            $self->reconnect_db;
        }
        else
        {
            $parent_socket->close();
            $self->fetcher_number( $i );
            $self->socket( $child_socket );
            $self->reconnect_db;
			$self->_run_fetcher();
        }
    }
}

# fork off fetching processes and then provide them with requests
sub crawl
{
    my ( $self ) = @_;

    $self->spawn_fetchers();

    my $socket_select = IO::Select->new();

    for my $fetcher ( @{ $self->fetchers } )
    {
        $socket_select->add( $fetcher->{ socket } );
    }

    my $provider = TProvider->new( $self );

    my $start_time = time;

    my $queued_downloads = [];
    while ( 1 )
    {
        if ( $self->timeout && ( ( time - $start_time ) > $self->timeout ) )
        {
            print STDERR "crawler timed out\n";
            last;
        }

        #print "wait for fetcher requests ...\n";
        for my $s ( $socket_select->can_read() )
        {
            my $fetcher_number = $s->getline();

            if ( !defined( $fetcher_number ) )
            {
                print STDERR "skipping fetcher in which we couldn't read the fetcher number\n";
                $socket_select->remove( $s );
                next;
            }

            chomp( $fetcher_number );

            #print "get fetcher $fetcher_number ping\n";

            if ( scalar( @{ $queued_downloads } ) == 0 )
            {
                print STDERR "refill queued downloads ...\n";
                $queued_downloads = $provider->provide_downloads();
            }

            if ( my $queued_download = shift( @{ $queued_downloads } ) )
            {
                # print STDERR "sending fetcher $fetcher_number download:" . $queued_download->{downloads_id} . "\n";
                $s->printflush( $queued_download->{ downloads_id } . "\n" );
            }
            else
            {
                #print STDERR "sending fetcher $fetcher_number none\n";
                $s->printflush( "none\n" );
                last;
            }

            # print "fetcher $fetcher_number request assigned\n";
        }

        $self->dbs->commit;
    }

    kill( 15, map { $_->{ pid } } @{ $self->{ fetchers } } );
    print "waiting 5 seconds for children to exit ...\n";
    sleep( 5 );
}

# fork this many processes
sub processes
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ processes } = $_[ 1 ];
    }

    return $_[ 0 ]->{ processes };
}

# sleep for up to this many seconds each time the provider fails to provide a request
sub sleep_interval
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ sleep_interval } = $_[ 1 ];
    }

    return $_[ 0 ]->{ sleep_interval };
}

# throttle each host to one request every this many seconds
sub throttle
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ throttle } = $_[ 1 ];
    }

    return $_[ 0 ]->{ throttle };
}

# time for crawler to run before exiting
sub timeout
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ timeout } = $_[ 1 ];
    }

    return $_[ 0 ]->{ timeout };
}

# interval to check downloads for pending downloads to add to queue
sub pending_check_interval
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ pending_check_interval } = $_[ 1 ];
    }

    return $_[ 0 ]->{ pending_check_interval };
}

# index of spawned process for spawned process
sub fetcher_number
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ fetcher_number } = $_[ 1 ];
    }

    return $_[ 0 ]->{ fetcher_number };
}

# list of child fetcher processes for root spawning processes
sub fetchers
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ fetchers } = $_[ 1 ];
    }

    return $_[ 0 ]->{ fetchers };
}

# socket to talk to parent process for spawned process
sub socket
{
    if ( defined( $_[ 1 ] ) )
    {
        $_[ 0 ]->{ socket } = $_[ 1 ];
    }

    return $_[ 0 ]->{ socket };
}


sub dbs
{
    my ( $self, $dbs ) = @_;

    if ( $dbs )
    {
        die( "use $self->reconnect_db to connect to db" );
    }

    defined( $self->{ dbs } ) || die "no database";

    return $self->{ dbs };
}

sub reconnect_db
{
    my ( $self ) = @_;

    if ( $self->{ dbs } )
    {
        $self->dbs->disconnect;
    }

    $self->{ dbs } = DB::connect_to_db(DB_LABEL);
    $self->dbs->dbh->{ AutoCommit } = 0;
}

1;
