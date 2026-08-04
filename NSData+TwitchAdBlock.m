#import "NSData+TwitchAdBlock.h"

static NSString *const TWABPlatform = @"switch_web_tv";
static NSString *const TWABPlayerType = @"pulsar";
static NSString *const TWABPlayerBackend = @"mediaplayer";

static BOOL TWABIsPlaybackTokenOperation(NSDictionary *operation) {
  NSString *operationName = [operation[@"operationName"] isKindOfClass:NSString.class]
                                ? operation[@"operationName"]
                                : nil;
  NSString *query = [operation[@"query"] isKindOfClass:NSString.class] ? operation[@"query"] : nil;

  NSArray<NSString *> *needles = @[
    @"StreamAccessToken", @"VodAccessToken", @"ClipAccessToken",
    @"PlaybackAccessToken", @"playbackAccessToken", @"streamPlaybackAccessToken",
    @"videoPlaybackAccessToken"
  ];
  for (NSString *needle in needles) {
    if ([operationName containsString:needle] || [query containsString:needle]) return YES;
  }
  return NO;
}

static void TWABApplyPlaybackProfile(NSMutableDictionary *dictionary) {
  if (![dictionary isKindOfClass:NSMutableDictionary.class]) return;

  dictionary[@"platform"] = TWABPlatform;
  dictionary[@"playerType"] = TWABPlayerType;
  dictionary[@"playerBackend"] = TWABPlayerBackend;
}

static void TWABMutatePlaybackTokenOperation(NSMutableDictionary *operation) {
  if (![operation isKindOfClass:NSMutableDictionary.class] || !TWABIsPlaybackTokenOperation(operation))
    return;

  NSMutableDictionary *variables = [operation[@"variables"] isKindOfClass:NSMutableDictionary.class]
                                       ? operation[@"variables"]
                                       : nil;
  if (variables) {
    // Twitch has used all of these variable layouts across app generations.
    TWABApplyPlaybackProfile(variables);

    NSMutableDictionary *params = [variables[@"params"] isKindOfClass:NSMutableDictionary.class]
                                      ? variables[@"params"]
                                      : nil;
    NSMutableDictionary *tokenParams =
        [variables[@"tokenParams"] isKindOfClass:NSMutableDictionary.class]
            ? variables[@"tokenParams"]
            : nil;
    NSMutableDictionary *input = [variables[@"input"] isKindOfClass:NSMutableDictionary.class]
                                     ? variables[@"input"]
                                     : nil;

    TWABApplyPlaybackProfile(params);
    TWABApplyPlaybackProfile(tokenParams);
    TWABApplyPlaybackProfile(input);

    if ([input[@"params"] isKindOfClass:NSMutableDictionary.class])
      TWABApplyPlaybackProfile(input[@"params"]);
  }

  // Non-persisted queries can hard-code the playback profile in the query text.
  NSString *query = [operation[@"query"] isKindOfClass:NSString.class] ? operation[@"query"] : nil;
  if (query.length) {
    NSMutableString *rewritten = query.mutableCopy;
    NSArray<NSArray<NSString *> *> *patterns = @[
      @[@"platform\\s*:\\s*\"[^\"]*\"", @"platform: \"switch_web_tv\""],
      @[@"playerType\\s*:\\s*\"[^\"]*\"", @"playerType: \"pulsar\""],
      @[@"playerBackend\\s*:\\s*\"[^\"]*\"", @"playerBackend: \"mediaplayer\""]
    ];
    for (NSArray<NSString *> *pair in patterns) {
      NSRegularExpression *regex =
          [NSRegularExpression regularExpressionWithPattern:pair[0] options:0 error:nil];
      [regex replaceMatchesInString:rewritten
                            options:0
                              range:NSMakeRange(0, rewritten.length)
                       withTemplate:pair[1]];
    }
    operation[@"query"] = rewritten;
  }
}

static void TWABMutatePlaybackTokenPayload(id json) {
  if ([json isKindOfClass:NSMutableDictionary.class]) {
    TWABMutatePlaybackTokenOperation(json);
  } else if ([json isKindOfClass:NSMutableArray.class]) {
    for (id operation in (NSMutableArray *)json) {
      if ([operation isKindOfClass:NSMutableDictionary.class])
        TWABMutatePlaybackTokenOperation(operation);
    }
  }
}

static void TWABRemoveFeedAdsFromOperation(NSMutableDictionary *operation) {
  if (![operation isKindOfClass:NSMutableDictionary.class]) return;

  NSMutableDictionary *data = [operation[@"data"] isKindOfClass:NSMutableDictionary.class]
                                  ? operation[@"data"]
                                  : nil;
  NSMutableDictionary *feedItems = [data[@"feedItems"] isKindOfClass:NSMutableDictionary.class]
                                       ? data[@"feedItems"]
                                       : nil;
  NSArray *edges = [feedItems[@"edges"] isKindOfClass:NSArray.class] ? feedItems[@"edges"] : nil;
  if (!edges) return;

  NSIndexSet *adIndexes = [edges indexesOfObjectsPassingTest:^BOOL(id edge, NSUInteger idx, BOOL *stop) {
    NSDictionary *node = [edge isKindOfClass:NSDictionary.class] &&
                                 [edge[@"node"] isKindOfClass:NSDictionary.class]
                             ? edge[@"node"]
                             : nil;
    return [node[@"__typename"] isEqualToString:@"FeedAd"];
  }];

  if (adIndexes.count) {
    NSMutableArray *filteredEdges = edges.mutableCopy;
    [filteredEdges removeObjectsAtIndexes:adIndexes];
    feedItems[@"edges"] = filteredEdges;
  }
}

@implementation NSData (TwitchAdBlock)
- (NSData *)twab_requestDataForRequest:(NSURLRequest *)request {
  if (!request || self.length == 0) return self;
  if (![request.URL.host isEqualToString:@"gql.twitch.tv"] ||
      ![request.URL.path isEqualToString:@"/gql"])
    return self;

  NSError *error = nil;
  id json = [NSJSONSerialization JSONObjectWithData:self
                                            options:NSJSONReadingMutableContainers
                                              error:&error];
  if (!json || error) return self;

  TWABMutatePlaybackTokenPayload(json);
  NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
  return modifiedData && !error ? modifiedData : self;
}

- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request {
  if (!request || self.length == 0) return self;
  if (![request.URL.host isEqualToString:@"gql.twitch.tv"] ||
      ![request.URL.path isEqualToString:@"/gql"])
    return self;

  NSError *error = nil;
  id json = [NSJSONSerialization JSONObjectWithData:self
                                            options:NSJSONReadingMutableContainers
                                              error:&error];
  if (!json || error) return self;

  if ([json isKindOfClass:NSMutableDictionary.class]) {
    TWABRemoveFeedAdsFromOperation(json);
  } else if ([json isKindOfClass:NSMutableArray.class]) {
    for (id operation in (NSMutableArray *)json) {
      if ([operation isKindOfClass:NSMutableDictionary.class])
        TWABRemoveFeedAdsFromOperation(operation);
    }
  }

  NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
  return modifiedData && !error ? modifiedData : self;
}
@end
