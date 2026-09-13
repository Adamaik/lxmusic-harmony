import localUnitTest from './LocalUnit.test';
import lxMetadataTest from './LxMetadata.test';
import musicSearchTest from './MusicSearch.test';
import txWySearchTest from './TxWySearch.test';

export default function testsuite() {
  localUnitTest();
  lxMetadataTest();
  musicSearchTest();
  txWySearchTest();
}