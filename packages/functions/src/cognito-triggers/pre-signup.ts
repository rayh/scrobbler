import { PreSignUpTriggerHandler } from "aws-lambda";

export const handler: PreSignUpTriggerHandler = async (event) => {
  event.response.autoConfirmUser = true;
  // Only auto-verify email if one was actually provided — Apple Sign In may
  // send a private relay address or no email at all on repeat sign-ins.
  if (event.request.userAttributes.email) {
    event.response.autoVerifyEmail = true;
  }
  return event;
};
