bool isLinkTag(int tag) => (tag & 0x20000000) != 0 || tag == 0x8000001B;
