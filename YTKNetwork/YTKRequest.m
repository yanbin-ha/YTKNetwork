//
//  YTKRequest.m
//
//  Copyright (c) 2012-2014 YTKNetwork https://github.com/yuantiku
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "YTKNetworkConfig.h"
#import "YTKRequest.h"
#import "YTKNetworkPrivate.h"

@interface YTKRequest()

@property (strong, nonatomic) id cacheJson;

@end

@implementation YTKRequest {
    BOOL _dataFromCache;
}

- (NSInteger)cacheTimeInSeconds {
    return 0;
}

- (long long)cacheVersion {
    return 0;
}

- (id)cacheSensitiveData {
    return nil;
}

- (void)checkDirectory:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDir;
    if (![fileManager fileExistsAtPath:path isDirectory:&isDir]) {
        [self createBaseDirectoryAtPath:path];
    } else {
        if (!isDir) {
            NSError *error = nil;
            [fileManager removeItemAtPath:path error:&error];
            [self createBaseDirectoryAtPath:path];
        }
    }
}

- (void)createBaseDirectoryAtPath:(NSString *)path {
    __autoreleasing NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
                                               attributes:nil error:&error];
    if (error) {
        YTKLog(@"create cache directory failed, error = %@", error);
    } else {
        [YTKNetworkPrivate addDoNotBackupAttribute:path];
    }
}

- (NSString *)cacheBasePath {
    NSString *pathOfLibrary = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *path = [pathOfLibrary stringByAppendingPathComponent:@"LazyRequestCache"];

    // 通过config对象，调整cache的存储路径
    NSArray *filters = [[YTKNetworkConfig sharedInstance] cacheDirPathFilters];
    if (filters.count > 0) {
        for (id<YTKCacheDirPathFilterProtocol> f in filters) {
            path = [f filterCacheDirPath:path withRequest:self];
        }
    }

    // 1，确保文件夹路径存在
    // 2，确保路径是一个文件夹，如果有同名的文件，删除
    [self checkDirectory:path];
    return path;
}

- (NSString *)cacheFileName {
    NSString *requestUrl = [self requestUrl];
    NSString *baseUrl = [YTKNetworkConfig sharedInstance].baseUrl;
    id argument = [self cacheFileNameFilterForRequestArgument:[self requestArgument]];
    NSString *requestInfo = [NSString stringWithFormat:@"Method:%ld Host:%@ Url:%@ Argument:%@ AppVersion:%@ Sensitive:%@",
                                                        (long)[self requestMethod], baseUrl, requestUrl,
                                                        argument, [YTKNetworkPrivate appVersionString], [self cacheSensitiveData]];
    NSString *cacheFileName = [YTKNetworkPrivate md5StringFromString:requestInfo];
    return cacheFileName;
}

- (NSString *)cacheFilePath {
    // cache文件的名字是一个md5字符串
    // 由http方法名(POST,GET...)，主url，全路径url，参数，app版本，等生成
    NSString *cacheFileName = [self cacheFileName];
    NSString *path = [self cacheBasePath];
    path = [path stringByAppendingPathComponent:cacheFileName];
    return path;
}

- (NSString *)cacheVersionFilePath {
    NSString *cacheVersionFileName = [NSString stringWithFormat:@"%@.version", [self cacheFileName]];
    NSString *path = [self cacheBasePath];
    path = [path stringByAppendingPathComponent:cacheVersionFileName];
    return path;
}

- (long long)cacheVersionFileContent {
    NSString *path = [self cacheVersionFilePath];
    NSFileManager * fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:path isDirectory:nil]) {
        NSNumber *version = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        return [version longLongValue];
    } else {
        return 0;
    }
}

- (int)cacheFileDuration:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // get file attribute
    NSError *attributesRetrievalError = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path
                                                             error:&attributesRetrievalError];
    if (!attributes) {
        YTKLog(@"Error get attributes for file at %@: %@", path, attributesRetrievalError);
        return -1;
    }
    int seconds = -[[attributes fileModificationDate] timeIntervalSinceNow];
    return seconds;
}

- (void)start {
    // 如果忽略cache，那么直接进行网络加载
    if (self.ignoreCache) {
        [super start];
        return;
    }
    // 从本地读取cache的版本
    long long cacheVersionFileContent = [self cacheVersionFileContent];
    // 查看本地缓存和需要的缓存版本号是否一致
    if (cacheVersionFileContent != [self cacheVersion]) {
        [super start];
        return;
    }

    // 如果没有设置cache的有效时间，那么认为不启用本地缓存
    if ([self cacheTimeInSeconds] < 0) {
        [super start];
        return;
    }

    // 获得cache文件的存储路径
    NSString *path = [self cacheFilePath];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // 如果cache文件不存在，那么就从网络上加载
    if (![fileManager fileExistsAtPath:path isDirectory:nil]) {
        [super start];
        return;
    }

    /* 获取文件从上次修改到现在的时间 */
    int seconds = [self cacheFileDuration:path];
    /**
     *  1，获取不到
     *  2，相距时间超过了有效期
     *  都要从网络重新获取数据
     **/
    if (seconds < 0 || seconds > [self cacheTimeInSeconds]) {
        [super start];
        return;
    }

    /**
     *  到这里说明，cache文件存在，并且没有过期
     *  那么要做的就是从本地cache文件中加载数据
     **/
    _cacheJson = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    if (_cacheJson == nil) {
        [super start];
        return;
    }

    /* 标识当前的数据是从本地cache当中获取到的 */
    _dataFromCache = YES;
    
    /* 调用hook代码通知请求即将完成 */
    [self requestCompleteFilter];
    
    /* 告诉该请求的代理对象，请求已经完成 */
    YTKRequest *strongSelf = self;
    [strongSelf.delegate requestFinished:strongSelf];
    if (strongSelf.successCompletionBlock) {
        strongSelf.successCompletionBlock(strongSelf);
    }
    [strongSelf clearCompletionBlock];
}

- (void)startWithoutCache {
    [super start];
}

- (id)cacheJson {
    if (_cacheJson) {
        return _cacheJson;
    } else {
        NSString *path = [self cacheFilePath];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:path isDirectory:nil] == YES) {
            _cacheJson = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        }
        return _cacheJson;
    }
}

- (BOOL)isDataFromCache {
    return _dataFromCache;
}

- (BOOL)isCacheVersionExpired {
    // check cache version
    long long cacheVersionFileContent = [self cacheVersionFileContent];
    if (cacheVersionFileContent != [self cacheVersion]) {
        return YES;
    } else {
        return NO;
    }
}

- (id)responseJSONObject {
    if (_cacheJson) {
        return _cacheJson;
    } else {
        return [super responseJSONObject];
    }
}

#pragma mark - Network Request Delegate

- (void)requestCompleteFilter {
    [super requestCompleteFilter];
    
    /* 将由服务器返回的json对象保存到本地 */
    [self saveJsonResponseToCacheFile:[super responseJSONObject]];
}

/**
 *  手动将其他请求的JsonResponse写入该请求的缓存
 *  比如AddNoteApi, UpdateNoteApi都会获得Note，且其与GetNoteApi共享缓存，可以通过这个接口写入GetNoteApi缓存
 **/
- (void)saveJsonResponseToCacheFile:(id)jsonResponse {
    /**
     *  1，用户设置了cache有效时间
     *  2，该请求不是从本地cache获取的
     *  只有这样的回应包才需要缓存
     **/
    if ([self cacheTimeInSeconds] > 0 && ![self isDataFromCache]) {
        NSDictionary *json = jsonResponse;
        if (json != nil) {
            [NSKeyedArchiver archiveRootObject:json toFile:[self cacheFilePath]];
            [NSKeyedArchiver archiveRootObject:@([self cacheVersion]) toFile:[self cacheVersionFilePath]];
        }
    }
}

@end
