

private class PreparedFileCluster : InterlockedNotificationObject {
    public Gee.ArrayList<PreparedFile> list;
    public PreparedFileCluster(Gee.ArrayList<PreparedFile> list) {
        this.list = list;
    }
}

