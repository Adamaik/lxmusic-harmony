import listDescTest from './ListDesc.test';
import localMusicTest from './LocalMusic.test';
import localUnitTest from './LocalUnit.test';
import lyricMatchTest from './LyricMatch.test';
import lxMetadataTest from './LxMetadata.test';
import musicSearchTest from './MusicSearch.test';
import playlistLinkTest from './PlaylistLink.test';
import shuffleBagTest from './ShuffleBag.test';
import txWySearchTest from './TxWySearch.test';

export default function testsuite() {
  listDescTest();
  localMusicTest();
  localUnitTest();
  lyricMatchTest();
  lxMetadataTest();
  musicSearchTest();
  playlistLinkTest();
  shuffleBagTest();
  txWySearchTest();
}