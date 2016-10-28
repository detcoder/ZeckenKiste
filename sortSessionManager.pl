use utf8;

# sortSessionManager.pl
# 
# FireFoxのセッションマネージャアドオンの、セッションファイル（.session）内のタブを並び替える
# デフォルト設定では、ニコ生の開始タブ時間を使って並び替える

# 使い方
# 
# コマンドラインからsessionファイルのパスを渡す
# Windows環境下ではショートカットファイル作ったりppしてEXEにするとD&Dで出来て楽

use strict;
use warnings;

use Encode;
use Encode::Guess;
use English;
use JSON;
use File::Copy qw/copy/;
use File::Path qw/mkpath/;
use File::Basename qw/basename dirname/;

# 日付処理
my($sec,$min,$hour,$day,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$year += 1900;
$mon  += 1;
map {$_ = "0".$_ if $_ < 10;} ($mon,$day,$hour,$min,$sec);

# 引数チェック
my($sesfilename, $sesfiledir) = ('', '');
if (scalar(@ARGV) != 1) {
	print("use this with one argument, is target filepath.\n\n");
	for (my $i = 1; $i <= scalar(@ARGV); $i++) {
		print "ARG$i: ".$ARGV[$i-1]."\n";
	}
	print("\nEnter ENTER.");
	$_ = <STDIN>;
	exit;
}

# ファイルシステムの文字コード(GUESS
my($filesystemencoding) = (guess_encoding($ARGV[0], qw/cp932 euc-jp/));
my($encname) = ($filesystemencoding->name);
if ($encname ne 'ascii') {
	binmode(STDOUT, ":encoding($encname)");
	binmode(STDERR, ":encoding($encname)");
}
$sesfilename = Encode::decode($encname, $ARGV[0]);
($sesfiledir) = dirname($sesfilename);

#--------------------------設定類--------------------------
#-対象のタブだと判断するタブ名のコンパイル済み正規表現、もしくは正規表現文字列。空文字だと判断しない
my($tabnameregexp) = (qr/開始\s-\sニコニコ生放送$/);
#-対象のタブだと判断するURLのコンパイル済み正規表現、もしくは正規表現文字列。空文字だと判断しない
my($taburlregexp)  = (qr/^http:\/\/live\.nicovideo\.jp\/watch\/lv\d+/);
#-対象のタブグループだと判断するグループ名のコンパイル済み正規表現。空文字だと以下略
my($tabgroupregexp) = ('');
#-バックアップファイルの拡張子。空文字列なら作らない
my($baksuffix)     = ("$year$mon$day.$hour$min$sec");
#-バックアップファイルの格納先ディレクトリ。空文字なら作らず、対象セッションファイルと同じ所に作る
my($bakdir)      = ("$sesfiledir/BAK.script");
#-ログファイルの名前。同名は上書き。空文字列なら作らない。
my($logfilename) = ("$sesfiledir/sorttabsLOG.$year$mon$day.$hour$min$sec.txt");
#-対象でないタブを前に置くかどうか。
my($putfrontnontargettab) = (1);
#-重複したタブ（グループIDとURLで判断）を除外するかどうか。処理ログでは=で表示
my($killDUPE)    = (1);
#-その他
my($sortfuncregexp) = (qr/\s(\d+\/\d+\/\d+\s\d+:\d+)開始\s-\sニコニコ生放送$/); # sortの関数用

#-並び替えに利用するサブルーチン。関数でないならタイトル文字ソート
# 渡されるリストはfrom_json->{'windows'}[0]{'tabs'}の内、上記条件を突破したもの
my($sortfunc) = sub {
	my($aactive, $bactive) = ($a->{'index'}, $b->{'index'});
	map {defined($_)?$_ -= 1:$_ = 0;} ($aactive, $bactive);
	my($atimestr) = $a->{'entries'}[$aactive]{'title'} =~ m/$sortfuncregexp/;
	my($btimestr) = $b->{'entries'}[$bactive]{'title'} =~ m/$sortfuncregexp/;
	
	if (defined($atimestr) xor defined($btimestr)) {
		return -1 if defined($atimestr);
		return 1;
	}
	elsif (!defined($atimestr)) {
		return $a->{'entries'}[$aactive]{'url'} cmp $b->{'entries'}[$bactive]{'url'};
	}
	else {
		return $atimestr cmp $btimestr;
	}
};

#サブルーチン郡
sub getINDEX($)
{
	return exists($_[0]->{'index'}) ? $_[0]->{'index'} - 1 : undef;
}

sub getTITLE($)
{
	my($activeindex) = (getINDEX($_[0]));
	return defined($activeindex) ?
		exists($_[0]->{'entries'}[$activeindex]{'title'}) && defined($_[0]->{'entries'}[$activeindex]{'title'}) ?
			$_[0]->{'entries'}[$activeindex]{'title'}
			: ''
		: undef;
}

sub getURL($)
{
	my($activeindex) = (getINDEX($_[0]));
	return defined($activeindex) ?
		exists($_[0]->{'entries'}[$activeindex]{'url'}) && defined($_[0]->{'entries'}[$activeindex]{'url'}) ?
			$_[0]->{'entries'}[$activeindex]{'url'}
			: ''
		: undef;
}

sub getGROUPID($)
{
	if ($_[0]->{'extData'}{'tabview-tab'}) {
		my($groupid) = $_[0]->{'extData'}{'tabview-tab'} =~ m/"groupID":(\d+)/;
		return defined($groupid) ? $groupid : '';
	}
	else {
		return '';
	}
}

# ログファイル処理
my($logfile) = (undef);
if ($logfilename) {
	open($logfile, '>:utf8', Encode::encode($encname, $logfilename))
		or die("could not open logfile $logfile");
	print($logfile "sortSessionManager\n$year/$mon/$day $hour:$min:$sec\n");
	print($logfile "TargetFile: $sesfilename\n");
	print($logfile "FileSystemEncoding: $encname\n\n");
}
my($prejson, $jsonval) = (undef, undef); #JSON前のデータとJSONのデータ

open(my $sesfile, '<:utf8', Encode::encode($encname, $sesfilename))
	or die("could not open $sesfilename");
foreach $_ (<$sesfile>) {
	if (m/^{.+?}$/) {
		chomp();
		$jsonval = from_json($_);
	}
	else {
		$prejson .= $_;
	}
}
close($sesfile);

my(@targettabs, @nontargettabs) = ()x2; #処理対象のタブと処理対象外のタブ
my(%targettabid, @tabids) = ()x2; #処理対象のタブのIDリスト, セッションファイル内のリスト

#タブグループ関連
my(@tabgrouptokens)
	= $jsonval->{'windows'}[0]{'extData'}{'tabview-group'} =~ m/("title":".*?","id":\d+)/g;
print $logfile "TABGROUPS:".scalar(@tabgrouptokens)."\n";
foreach my $tabgrouptoken (@tabgrouptokens) {
	my($groupname, $groupid) = $tabgrouptoken =~ m/title":"(.*?)","id":(\d+)/;
	$groupname = '' if !defined($groupname);
	print $logfile "TITLE:'$groupname' ID:$groupid" if $logfile;
	if ($groupname ne '' && $tabgroupregexp ne '' && $groupname =~ m/$tabgroupregexp/) {
		print $logfile " TARGET";
		$targettabid{$groupid} = 1;
	}
	elsif ($tabgroupregexp eq '') {
		print $logfile " TARGET";
	}
	print $logfile "\n" if $logfile;
}
undef(%targettabid) if !defined($tabgroupregexp) || $tabgroupregexp eq '';

print $logfile "\n" if $logfile;

# タブの振り分け
my($tabexists);
foreach my $tabentry (@{$jsonval->{'windows'}[0]{'tabs'}}) {
	my($tabname, $taburl, $tabid) = (getTITLE($tabentry), getURL($tabentry), getGROUPID($tabentry));
	
	if ($killDUPE && exists($tabexists->{$tabid}{$taburl})) {
		print $logfile "= $tabname\n$taburl ID:$tabid\n" if $logfile;
		next;
	}
	$tabexists->{$tabid}{$taburl} = 1;
	
	if (($tabnameregexp eq '' || $tabname =~ m/$tabnameregexp/)
		&& ($taburlregexp eq '' || $taburl =~ m/$taburlregexp/)
		&& (!%targettabid || exists($targettabid{$tabid}))
	) {
		push(@targettabs, $tabentry);
		print $logfile "+ $tabname\n$taburl ID:$tabid\n" if $logfile;
	}
	else {
		push(@nontargettabs, $tabentry);
		print $logfile "- $tabname\n$taburl ID:$tabid\n" if $logfile;
	}
}
print $logfile "\n" if $logfile;

# 並び替え
@targettabs = sort $sortfunc @targettabs if @targettabs && $sortfunc;
@targettabs = sort @targettabs if @targettabs && (!defined($sortfunc) || $sortfunc eq '');

# ログ記載
sub writeLOG($)
{
	my($title, $url) = (getTITLE($_[0]), getURL($_[0]));
	if ($title ne '') {
		print $logfile "$title\n" if $logfile;
	}
	else {
		print $logfile "NOTITLE($url)\n" if $logfile;
	}
}

if ($logfile) {
	sub sortfuncByTABTITLE()
	{
		my($atitle, $btitle) = (getTITLE($a), getTITLE($b));
		if (defined($atitle) xor defined($btitle)) {
			# どちらかが規定のタブではない
			return defined($atitle) ? 1 : -1;
		}
		elsif (defined($atitle)) {
			# 両方共既定のタブ
			if ($atitle eq $btitle) {
				return getURL($a) cmp getURL($b);
			}
			else {
				return $atitle cmp $btitle;
			}
		}
		else {
			return 0;
		}
	}
	
	print($logfile "-----TARGET TABS(sorted by name)\n");
	map { writeLOG($_); } sort sortfuncByTABTITLE @targettabs;
	print($logfile "-----NON TARGET TABS(sorted by name)\n") if scalar(@nontargettabs) > 0;
	map { writeLOG($_); } sort sortfuncByTABTITLE @nontargettabs;
}

if ($putfrontnontargettab) {
	push(@nontargettabs, @targettabs);
	@targettabs = @nontargettabs;
}
else {
	push(@targettabs, @nontargettabs);
}

print $logfile "\n\n" if $logfile;

print($logfile "-----RESULT\n") if $logfile;
map { writeLOG($_); } @targettabs if $logfile;

# 上書き保存
$jsonval->{'windows'}[0]{'tabs'} = \@targettabs;
# バックアップ
if (defined($baksuffix) && $baksuffix ne '') {
	if (defined($bakdir) && $bakdir ne '') {
		mkpath(Encode::encode($encname, $bakdir)) unless -e Encode::encode($encname, $bakdir);
		copy(Encode::encode($encname, $sesfilename),
			Encode::encode($encname, "$bakdir/".basename($sesfilename).".$baksuffix"))
			or die("could not create backup file $bakdir/".basename($sesfilename).".$baksuffix");
		print($logfile "\nBackupFile: $bakdir/".basename($sesfilename).".$baksuffix\n") if $logfile;
	}
	else {
		copy(Encode::encode($encname, $sesfilename),
			Encode::encode($encname, "$sesfilename.$baksuffix"))
			or die("could not create backup file $sesfilename.$baksuffix");
		print($logfile "\nBackupFile: $sesfilename.$baksuffix\n") if $logfile;
	}
}
open($sesfile, '>:utf8', Encode::encode($encname, $sesfilename))
	or die("could not open $sesfilename to OVERWRITE.");
print $sesfile $prejson;
print $sesfile to_json($jsonval);
print $sesfile "\n";
close($sesfile);

close($logfile) if $logfile;
