import { DefineAuthChallengeTriggerHandler } from "aws-lambda";

export const handler: DefineAuthChallengeTriggerHandler = async (event) => {
  console.log("DefineAuthChallenge event:", JSON.stringify({
    triggerSource: event.triggerSource,
    userName: event.userName,
    sessionLength: event.request.session.length,
    session: event.request.session.map(s => ({
      challengeName: s.challengeName,
      challengeResult: s.challengeResult,
    })),
  }));

  event.response.issueTokens = false;
  event.response.failAuthentication = false;

  if (event.request.session.length > 0) {
    const lastChallenge = event.request.session[event.request.session.length - 1];

    if (lastChallenge.challengeName === "CUSTOM_CHALLENGE") {
      event.response.issueTokens = lastChallenge.challengeResult;
      event.response.failAuthentication = !lastChallenge.challengeResult;
    }
  }

  if (!event.response.failAuthentication && !event.response.issueTokens) {
    event.response.challengeName = "CUSTOM_CHALLENGE";
  }

  console.log("DefineAuthChallenge response:", JSON.stringify(event.response));
  return event;
};
