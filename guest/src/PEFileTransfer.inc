/* Included inside PEAgent's implementation. Small XML messages describe the
 * operation; ZIP bytes travel on WebDAV, never on the surface/control socket. */
- (void)fileResult:(NSDictionary *)result
{
    NSString *error=nil;
    NSData *data=[NSPropertyListSerialization dataFromPropertyList:result
        format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    [error release];
    if(data)[self send:@"FILERESULT" data:data];
}

- (void)fileError:(NSString *)error request:(NSDictionary *)request
{
    [self fileResult:[NSDictionary dictionaryWithObjectsAndKeys:
        [request objectForKey:@"request"],@"request",error,@"error",nil]];
}

- (pid_t)fileWindowPID:(int)wid
{
    ProcessSerialNumber process={0,kNoProcess};int cid=_CGSDefaultConnection();
    while(GetNextProcess(&process)==noErr) {
        CGSConnectionID connection=0;CGSWindowID windows[256];int count=0,i;
        if(CGSGetConnectionIDForPSN(cid,&process,&connection)!=0 ||
           CGSGetOnScreenWindowList(cid,connection,256,windows,&count)!=0)continue;
        for(i=0;i<count;i++)if(windows[i]==wid){pid_t pid=0;GetProcessPID(&process,&pid);return pid;}
    }
    return 0;
}

/* Tiger Finder is Carbon: it does not publish NSDragPboard. Its accessibility
 * Finder items do expose real file URLs. Arm only a real item under the press,
 * never a scrollbar, empty selection rectangle, toolbar or stale selection. */
- (void)armFileDrag:(NSString *)spec
{
    fileDragWindow=0;[fileDragSourcePath release];fileDragSourcePath=nil;[fileDragPaths release];fileDragPaths=nil;
    int wid,x,y;if(sscanf([spec UTF8String],"%d %d %d",&wid,&x,&y)!=3)return;
    pid_t pid=[self fileWindowPID:wid];if(pid<=0)return;
    AXUIElementRef app=AXUIElementCreateApplication(pid),hit=NULL;
    AXUIElementCopyElementAtPosition(app,x,y,&hit);CFRelease(app);
    int depth;
    for(depth=0;hit && depth<6;depth++) {
        CFTypeRef role=NULL,url=NULL,parent=NULL;
        AXUIElementCopyAttributeValue(hit,kAXRoleAttribute,&role);
        if(role && [(NSString *)role isEqualToString:@"AXFinderItem"]) {
            AXUIElementCopyAttributeValue(hit,CFSTR("AXURL"),&url);
            NSURL *file=[(id)url isKindOfClass:[NSURL class]]?(NSURL *)url:
                ([(id)url isKindOfClass:[NSString class]]?[NSURL URLWithString:(NSString *)url]:nil);
            if([file isFileURL]) {
                fileDragSourcePath=[[[file path] stringByStandardizingPath] copy];fileDragWindow=wid;
                NSMutableArray *paths=[NSMutableArray array];CFTypeRef selected=NULL,container=NULL,children=NULL;
                AXUIElementCopyAttributeValue(hit,kAXSelectedAttribute,&selected);
                if(selected && CFGetTypeID(selected)==CFBooleanGetTypeID() && CFBooleanGetValue(selected)) {
                    AXUIElementCopyAttributeValue(hit,kAXParentAttribute,&container);
                    if(container)AXUIElementCopyAttributeValue((AXUIElementRef)container,kAXSelectedChildrenAttribute,&children);
                    if(children && CFGetTypeID(children)==CFArrayGetTypeID()) {
                        CFIndex i,n=CFArrayGetCount(children);
                        for(i=0;i<n && i<257;i++) {
                            CFTypeRef u=NULL;AXUIElementCopyAttributeValue((AXUIElementRef)CFArrayGetValueAtIndex(children,i),CFSTR("AXURL"),&u);
                            NSURL *f=[(id)u isKindOfClass:[NSURL class]]?(NSURL *)u:([(id)u isKindOfClass:[NSString class]]?[NSURL URLWithString:(NSString *)u]:nil);
                            if([f isFileURL])[paths addObject:[[f path] stringByStandardizingPath]];
                            if(u)CFRelease(u);
                        }
                    }
                }
                if(selected)CFRelease(selected);if(container)CFRelease(container);if(children)CFRelease(children);
                if(![paths containsObject:fileDragSourcePath]){[paths removeAllObjects];[paths addObject:fileDragSourcePath];}
                fileDragPaths=[paths copy];
            }
            if(url)CFRelease(url);if(role)CFRelease(role);CFRelease(hit);return;
        }
        if(role)CFRelease(role);
        AXUIElementCopyAttributeValue(hit,kAXParentAttribute,&parent);CFRelease(hit);hit=(AXUIElementRef)parent;
    }
    if(hit)CFRelease(hit);
}

- (NSString *)fileFinderFolder:(int)wid selection:(BOOL)selection
{
    CGRect r;pid_t pid=[self fileWindowPID:wid];
    if(CGSGetScreenRectForWindow(_CGSDefaultConnection(),wid,&r)!=0)return nil;
    if(pid<=0)return nil;
    NSDictionary *app=nil;NSEnumerator *apps=[[[NSWorkspace sharedWorkspace] launchedApplications] objectEnumerator];
    while((app=[apps nextObject]))if([[app objectForKey:@"NSApplicationProcessIdentifier"] intValue]==pid)break;
    if(![[app objectForKey:@"NSApplicationBundleIdentifier"] isEqualToString:@"com.apple.finder"])return nil;
    /* Finder's scripting bounds omit the title bar on some Tiger views. Match
     * both edges and require a unique candidate, never default to front window. */
    NSString *script=[NSString stringWithFormat:
        @"tell application \"Finder\"\nset found to {}\nrepeat with wi from 1 to (count of Finder windows)\nset w to Finder window wi\n"
         "set b to bounds of w\n"
         "if (item 1 of b) >= %d and (item 1 of b) <= %d and (item 3 of b) >= %d and (item 3 of b) <= %d and (item 2 of b) >= %d and (item 2 of b) <= %d and (item 4 of b) >= %d and (item 4 of b) <= %d then set end of found to (id of w)\n"
         "end repeat\nif (count found) is not 1 then error \"The Finder window could not be identified.\"\n"
         "set w to Finder window id (item 1 of found)\n%@\nend tell",
        (int)r.origin.x-3,(int)r.origin.x+3,(int)(r.origin.x+r.size.width)-3,(int)(r.origin.x+r.size.width)+3,
        (int)r.origin.y-3,(int)r.origin.y+25,(int)(r.origin.y+r.size.height)-3,(int)(r.origin.y+r.size.height)+3,
        selection ? @"if (id of w) is not (id of front Finder window) then error \"The source window is no longer focused.\"\nreturn POSIX path of (target of w as alias)" : @"return POSIX path of (target of w as alias)"];
    NSAppleScript *as=[[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"with timeout of 2 seconds\n%@\nend timeout",script]] autorelease];
    NSDictionary *err=nil;NSAppleEventDescriptor *value=[as executeAndReturnError:&err];
    return [value stringValue];
}

- (void)fileTransfer:(NSDictionary *)request
{
    NSString *rid=[request objectForKey:@"request"],*token=[request objectForKey:@"token"],*action=[request objectForKey:@"action"];
    NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"] invertedSet];
    if(![rid isKindOfClass:[NSString class]] || [rid length]!=36 || [rid rangeOfCharacterFromSet:bad].location!=NSNotFound)return;
    if(![token isKindOfClass:[NSString class]] || [token length]!=36 || [token rangeOfCharacterFromSet:bad].location!=NSNotFound){[self fileError:@"Invalid file transfer identifier." request:request];return;}
    if(![action isKindOfClass:[NSString class]]){[self fileError:@"Invalid file transfer action." request:request];return;}
    if(([request objectForKey:@"window"] && ![[request objectForKey:@"window"] isKindOfClass:[NSNumber class]]) ||
       ([request objectForKey:@"application"] && ![[request objectForKey:@"application"] isKindOfClass:[NSNumber class]])) {
        [self fileError:@"Invalid file transfer target." request:request];return;
    }
    if(!fileTransfers)fileTransfers=[[NSMutableDictionary alloc] init];
    /* Expire abandoned selection/destination tickets, not active workers. */
    NSArray *keys=[fileTransfers allKeys];unsigned i;
    for(i=0;i<[keys count];i++) {
        NSString *key=[keys objectAtIndex:i];NSDictionary *t=[fileTransfers objectForKey:key];
        if(-[[t objectForKey:@"created"] timeIntervalSinceNow]>([t objectForKey:@"paths"] && ![t objectForKey:@"exporting"]?120:1800))[fileTransfers removeObjectForKey:key];
    }
    if([action isEqualToString:@"destination"] || [action isEqualToString:@"selection"]) {
        if([fileTransfers count]>=64){[self fileError:@"Too many pending file transfers. Try again shortly." request:request];return;}
        int wid=[[request objectForKey:@"window"] intValue],pid=[[request objectForKey:@"application"] intValue];
        NSMutableDictionary *ticket=[NSMutableDictionary dictionaryWithObjectsAndKeys:[NSDate date],@"created",nil];
        if([action isEqualToString:@"selection"]) {
            NSArray *dragPaths=[request objectForKey:@"dragPaths"];
            if(!dragPaths) {
                if(fileDragWindow!=wid || !fileDragPaths){[self fileError:@"No file drag is active in this Finder window." request:request];return;}
                NSMutableDictionary *settled=[NSMutableDictionary dictionaryWithDictionary:request];
                [settled setObject:fileDragPaths forKey:@"dragPaths"];
                fileDragWindow=0;
                CGPostKeyboardEvent(0,53,true);CGPostKeyboardEvent(0,53,false);
                [self performSelector:@selector(fileTransfer:) withObject:settled afterDelay:0.12];return;
            }
            if(wid<=0 || ![self fileFinderFolder:wid selection:YES]){[self fileError:@"Drag files from a guest Finder folder window." request:request];return;}
            int j;
            NSMutableArray *paths=[NSMutableArray array],*entries=[NSMutableArray array];
            int n=[dragPaths count];
            if(n<1 || n>256){[self fileError:@"Select up to 256 files or folders in Finder." request:request];return;}
            for(j=1;j<=n;j++) {
                NSString *path=[dragPaths objectAtIndex:j-1];BOOL dir=NO;
                if(![path isKindOfClass:[NSString class]] || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir]){[self fileError:@"A selected file is no longer available." request:request];return;}
                path=[path stringByStandardizingPath];
                [paths addObject:path];[entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    [path lastPathComponent],@"name",[NSNumber numberWithBool:dir],@"directory",nil]];
            }
            [ticket setObject:paths forKey:@"paths"];[fileTransfers setObject:ticket forKey:token];
            [self fileResult:[NSDictionary dictionaryWithObjectsAndKeys:rid,@"request",entries,@"entries",nil]];return;
        }
        NSString *folder=nil;
        if(pid>0) {
            ProcessSerialNumber psn;
            if(GetProcessForPID(pid,&psn)!=noErr){[self fileError:@"The guest application has quit." request:request];return;}
            /* Keep document copies after Open Documents: applications may keep
             * editing them long after the transfer has completed. */
            folder=[[@"~/Documents/PowerEmu Imports" stringByExpandingTildeInPath] stringByAppendingPathComponent:token];
            [ticket setObject:[NSNumber numberWithInt:pid] forKey:@"application"];
        } else if(wid>0) {
            folder=[self fileFinderFolder:wid selection:NO];
            if(!folder) {
                pid_t windowPID=[self fileWindowPID:wid];
                if(windowPID>0) {
                    NSDictionary *ownerApp=nil;NSEnumerator *owners=[[[NSWorkspace sharedWorkspace] launchedApplications] objectEnumerator];
                    while((ownerApp=[owners nextObject]))if([[ownerApp objectForKey:@"NSApplicationProcessIdentifier"] intValue]==windowPID)break;
                    if([[ownerApp objectForKey:@"NSApplicationBundleIdentifier"] isEqualToString:@"com.apple.finder"]){[self fileError:@"This Finder window does not identify a writable folder. Open the destination folder and try again." request:request];return;}
                    folder=[[@"~/Documents/PowerEmu Imports" stringByExpandingTildeInPath] stringByAppendingPathComponent:token];
                    [ticket setObject:[NSNumber numberWithInt:windowPID] forKey:@"application"];
                }
            }
        } else folder=[@"~/Desktop" stringByExpandingTildeInPath];
        if(!folder){[self fileError:@"The destination folder is no longer available." request:request];return;}
        [ticket setObject:folder forKey:@"folder"];[fileTransfers setObject:ticket forKey:token];
        [self fileResult:[NSDictionary dictionaryWithObject:rid forKey:@"request"]];return;
    }
    NSDictionary *ticket=[fileTransfers objectForKey:token];
    if(!ticket){[self fileError:@"This drag has expired. Drag the files again." request:request];return;}
    if(![action isEqualToString:@"export"] && ![action isEqualToString:@"import"])return;
    if(fileTransferWorkers>=16){[self fileError:@"Too many file transfers are running. Try again shortly." request:request];return;}
    if([action isEqualToString:@"export"]) {
        NSMutableDictionary *renewed=[NSMutableDictionary dictionaryWithDictionary:ticket];
        [renewed setObject:[NSDate date] forKey:@"created"];
        [renewed setObject:[NSNumber numberWithBool:YES] forKey:@"exporting"];
        [fileTransfers setObject:renewed forKey:token];ticket=renewed;
    }
    NSMutableDictionary *job=[NSMutableDictionary dictionaryWithDictionary:request];
    [job setObject:ticket forKey:@"ticket"];
    if([action isEqualToString:@"import"])[fileTransfers removeObjectForKey:token];
    if(!fileTransferLock)fileTransferLock=[[NSLock alloc] init];
    fileTransferWorkers++;
    [NSThread detachNewThreadSelector:@selector(fileTransferWorker:) toTarget:self withObject:job];
}

- (void)fileTransferFinished:(NSDictionary *)result
{
    fileTransferWorkers--;
    NSString *folder=[result objectForKey:@"folder"];
    if(folder)[[NSWorkspace sharedWorkspace] noteFileSystemChanged:folder];
    NSArray *paths=[result objectForKey:@"opened"];
    int pid=[[result objectForKey:@"application"] intValue];
    if(paths && pid>0) {
        ProcessSerialNumber psn;AEDesc target={typeNull,NULL};AppleEvent event={typeNull,NULL},reply={typeNull,NULL};AEDescList list={typeNull,NULL};
        OSStatus status=GetProcessForPID(pid,&psn);
        if(status==noErr)status=AECreateDesc(typeProcessSerialNumber,&psn,sizeof(psn),&target);
        if(status==noErr)status=AECreateAppleEvent(kCoreEventClass,kAEOpenDocuments,&target,kAutoGenerateReturnID,kAnyTransactionID,&event);
        if(status==noErr)status=AECreateList(NULL,0,false,&list);
        unsigned i;
        for(i=0;status==noErr && i<[paths count];i++) {
            FSRef ref;status=FSPathMakeRef((const UInt8 *)[[paths objectAtIndex:i] fileSystemRepresentation],&ref,NULL);
            if(status==noErr)status=AEPutPtr(&list,0,typeFSRef,&ref,sizeof(ref));
        }
        if(status==noErr)status=AEPutParamDesc(&event,keyDirectObject,&list);
        if(status==noErr)status=AESend(&event,&reply,kAENoReply|kAECanInteract,kAENormalPriority,kAEDefaultTimeout,NULL,NULL);
        AEDisposeDesc(&list);AEDisposeDesc(&event);AEDisposeDesc(&target);AEDisposeDesc(&reply);
        if(status!=noErr) {
            [self fileError:[NSString stringWithFormat:@"The files were copied to %@, but the application could not open them.",folder] request:result];return;
        }
        SetFrontProcess(&psn);
    }
    [self fileResult:result];
}

- (BOOL)fileRun:(NSString *)tool arguments:(NSArray *)arguments
{
    NSTask *task=[[[NSTask alloc] init] autorelease];[task setLaunchPath:tool];[task setArguments:arguments];
    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];[task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {[task launch];[task waitUntilExit];return [task terminationStatus]==0;} @catch(NSException *e){return NO;}
    return NO;
}

- (BOOL)fileTreeSafe:(NSString *)path
{
    NSFileManager *fm=[[[NSFileManager alloc] init] autorelease];
    NSString *type=[[fm fileAttributesAtPath:path traverseLink:NO] objectForKey:NSFileType];
    if(![type isEqualToString:NSFileTypeRegular] && ![type isEqualToString:NSFileTypeDirectory])return NO;
    if([type isEqualToString:NSFileTypeDirectory]) {
        NSEnumerator *e=[[fm directoryContentsAtPath:path] objectEnumerator];NSString *child;
        while((child=[e nextObject]))if(![self fileTreeSafe:[path stringByAppendingPathComponent:child]])return NO;
    }
    return YES;
}

- (void)fileTransferWorker:(NSDictionary *)job
{
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];[NSThread setThreadPriority:0.2];[fileTransferLock lock];
    NSFileManager *fm=[[[NSFileManager alloc] init] autorelease];
    NSString *token=[job objectForKey:@"token"],*rid=[job objectForKey:@"request"],*error=nil;
    NSDictionary *ticket=[job objectForKey:@"ticket"];
    NSString *temp=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"PowerEmu-" stringByAppendingString:rid]];
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithObject:rid forKey:@"request"];
    const char *override=getenv("PE_TRANSFER_URL");
    NSString *base=override?[NSString stringWithUTF8String:override]:@"http://10.0.2.100/PowerEmu%20Drop";
    if(![fm createDirectoryAtPath:temp attributes:nil])error=@"The guest could not create a temporary transfer folder.";
    @try {
        if(!error && [[job objectForKey:@"action"] isEqualToString:@"export"]) {
            NSArray *paths=[ticket objectForKey:@"paths"];int index=[[job objectForKey:@"index"] intValue];
            if(!paths || index<0 || index>=[paths count])error=@"Invalid source file.";
            else {
                NSString *path=[paths objectAtIndex:index],*zip=[temp stringByAppendingPathComponent:@"item.zip"];
                BOOL directory=NO;[fm fileExistsAtPath:path isDirectory:&directory];
                NSMutableArray *arguments=[NSMutableArray arrayWithObjects:@"-c",@"-k",@"--sequesterRsrc",nil];
                if(directory)[arguments addObject:@"--keepParent"];
                [arguments addObject:path];[arguments addObject:zip];
                if(![self fileTreeSafe:path])error=@"Folders containing symbolic links or special files cannot be dragged yet. Copy an archive instead.";
                else if(![self fileRun:@"/usr/bin/ditto" arguments:arguments])error=@"The guest could not read or archive this file.";
                else if(![self fileRun:@"/usr/bin/curl" arguments:[NSArray arrayWithObjects:@"--fail",@"--silent",@"--connect-timeout",@"10",@"--max-time",@"900",@"-T",zip,[NSString stringWithFormat:@"%@/%@/%d.zip",base,token,index],nil]])error=@"The guest could not send the file to the host.";
            }
        } else if(!error) {
            NSArray *names=[job objectForKey:@"names"];NSString *folder=[ticket objectForKey:@"folder"];
            NSMutableArray *opened=[NSMutableArray array];unsigned i;
            if(![names isKindOfClass:[NSArray class]] || [names count]<1 || [names count]>256 || !folder)error=@"Invalid destination transfer.";
            if(!error && ![fm fileExistsAtPath:folder] && [ticket objectForKey:@"application"]) {
                NSString *parent=[folder stringByDeletingLastPathComponent];
                if(![fm fileExistsAtPath:parent])[fm createDirectoryAtPath:parent attributes:nil];
                [fm createDirectoryAtPath:folder attributes:nil];
            }
            if(!error && ![fm isWritableFileAtPath:folder])error=@"The destination folder is not writable.";
            for(i=0;!error && i<[names count];i++) {
                NSString *name=[names objectAtIndex:i];
                if(![name isKindOfClass:[NSString class]] || ![name length] || [name isEqualToString:@"."] || [name isEqualToString:@".."] || [name rangeOfString:@"/"].location!=NSNotFound || [name rangeOfString:@"\\"].location!=NSNotFound){error=@"Invalid transfer filename.";break;}
                NSString *zip=[temp stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.zip",i]];
                NSString *extract=[temp stringByAppendingPathComponent:[NSString stringWithFormat:@"%d",i]];
                [fm createDirectoryAtPath:extract attributes:nil];
                if(![self fileRun:@"/usr/bin/curl" arguments:[NSArray arrayWithObjects:@"--fail",@"--silent",@"--connect-timeout",@"10",@"--max-time",@"900",@"-o",zip,[NSString stringWithFormat:@"%@/%@/%d.zip",base,token,i],nil]]){error=@"The file could not be received. Check the shared connection and available guest disk space.";break;}
                NSData *archive=[NSData dataWithContentsOfMappedFile:zip];
                if(!archive || !PETransferZipSafe([archive bytes],[archive length],[name UTF8String])){error=@"Invalid or unsupported transfer archive (maximum 4 GB per item).";break;}
                if(![self fileRun:@"/usr/bin/ditto" arguments:[NSArray arrayWithObjects:@"-x",@"-k",zip,extract,nil]]){error=@"The file could not be extracted. Check guest disk space.";break;}
                NSString *source=[extract stringByAppendingPathComponent:name];
                if(![self fileTreeSafe:source]){error=@"This file contains unsupported links or special files.";break;}
                NSString *dest=[folder stringByAppendingPathComponent:name];int suffix=2;
                while([fm fileExistsAtPath:dest]) {
                    NSString *ext=[name pathExtension],*stem=[name stringByDeletingPathExtension];
                    NSString *next=[NSString stringWithFormat:@"%@ (%d)%@%@",stem,suffix++,[ext length]?@".":@"",ext];
                    dest=[folder stringByAppendingPathComponent:next];
                }
                // movePath refuses an existing destination; never delete user files.
                if(![fm movePath:source toPath:dest handler:nil]){error=@"A file could not be copied into the destination. Some earlier files may already have arrived.";break;}
                [opened addObject:dest];
            }
            if(folder)[result setObject:folder forKey:@"folder"];
            if(!error && [ticket objectForKey:@"application"]){[result setObject:opened forKey:@"opened"];[result setObject:[ticket objectForKey:@"application"] forKey:@"application"];}
            if(error && [opened count])error=[error stringByAppendingString:@" Some files have already been copied; check the destination before retrying."];
        }
    } @catch(NSException *e){error=@"The guest could not complete the transfer. Check the destination before retrying.";}
    if(error)[result setObject:error forKey:@"error"];
    [fm removeFileAtPath:temp handler:nil];[fileTransferLock unlock];
    [self performSelectorOnMainThread:@selector(fileTransferFinished:) withObject:result waitUntilDone:NO];
    [pool release];
}
