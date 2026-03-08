import React from 'react';

export const AuthWidget = ({ userToken }) => {
  const [session, setSession] = React.useState(null);

  const verifyToken = (token) => {
    const decoded = jwtDecode(token);
    setSession(decoded);
  };

  return (
    <div className="auth-widget">
      <Button onClick={() => verifyToken(userToken)}>
        Login
      </Button>
      {session && <ProfileBadge data={session} />}
    </div>
  );
};
