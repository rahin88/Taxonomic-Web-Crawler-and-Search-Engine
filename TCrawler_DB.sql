CREATE TYPE download_state AS ENUM ('error', 'fetching', 'pending', 'queued', 'success');    
CREATE TYPE download_type  AS ENUM ('archival_only','content');    
CREATE TYPE download_status  AS ENUM ('done','error','new','ready','queued');
create table downloads (
    downloads_id        	serial          	primary key,
    feeds_id			int			null references feeds,
    parent              	int             	null,
    url                 	varchar(2048)   	not null,
    location            	varchar(2048)   	null,
    host                	varchar(2048)   	not null,
    download_time       	timestamp       	not null,
    type                	download_type   	not null,
    state               	download_state  	not null,
    childs			int					not null default '0',
    priority            	int             	null,
    path                	text            	null,
    error_message       	text            	null,
    sequence            	int             	not null,
    extracted           	boolean         	not null default 'f',
    mm_hash_url         	varchar(20)     	null,
    mm_hash_location        varchar(20)     	null,
    download_id_of_old_copy int					null       
);
create table feeds (
	feed_id				serial			primary key,
	url				varchar(2048)		not null,
	mm_hash_url			varchar(20)		not null,
	last_download_time		timestamp		null
);


CREATE VIEW downloads_sites as select regexp_replace(host, $q$^(.)*?([^.]+)\.([^.]+)$$q$ ,E'\\2.\\3') as site, * from downloads;

CREATE INDEX hash_url ON downloads (mm_hash_url) ;
CREATE INDEX hash_location ON downloads (mm_hash_location) ;
CREATE INDEX index_location ON downloads (location) ;
