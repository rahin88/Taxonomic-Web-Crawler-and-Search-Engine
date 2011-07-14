

open MYFILE, "<", "/home/aditya/workspace/TCrawler/test/1";
my $myregex="my name is aditya";
my $count =0;
while (<MYFILE>)
				{
				my $myline = $_;
				while ($myline =~ /$myregex/g)
				{
						$count++;
				}
				}
my $temp_string = $count." ".$file;
print $count;