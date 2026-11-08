package android.widget;
import android.view.View;
public class Button { public View.OnClickListener listener; public void setOnClickListener(View.OnClickListener l) { listener=l; } public void click() { listener.onClick(new View()); } }
